// NoType fcitx5 addon: three quick Spaces in any input context ask the NoType daemon to
// translate the draft. Linux counterpart of TripleSpaceTriggerService.swift; it runs inside
// fcitx5, so it never blocks or throws into the event loop.
//
// The addon also listens on `$XDG_RUNTIME_DIR/notype/fcitx5.sock` so the daemon can commit the
// translation into the input context that reported the trigger, instead of pasting it through
// the clipboard. Each trigger carries a single-use token that names that context.

#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/trackableobject.h>
#include <fcitx-utils/unixfd.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/instance.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <list>
#include <memory>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include "commit_request.h"
#include "triple_space.h"

namespace {

FCITX_DEFINE_LOG_CATEGORY(notypeLog, "notype");
#define NOTYPE_INFO() FCITX_LOGC(notypeLog, Info)
#define NOTYPE_DEBUG() FCITX_LOGC(notypeLog, Debug)

constexpr size_t kMaxCommitConnections = 4;

// `$XDG_RUNTIME_DIR/notype/<name>`, the daemon's private runtime directory; empty without it.
std::string runtimeSocketPath(const char *name) {
    const char *runtimeDir = std::getenv("XDG_RUNTIME_DIR");
    if (!runtimeDir || !*runtimeDir) {
        return {};
    }
    return std::string(runtimeDir) + "/notype/" + name;
}

// Returns 0 or an errno.
int socketAddress(const std::string &path, sockaddr_un &address) {
    if (path.empty()) {
        return ENOENT;
    }
    address = {};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) {
        return ENAMETOOLONG;
    }
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    return 0;
}

// Writes one control request and closes without reading the reply. Returns 0 or an errno.
// `surroundingText` tells the daemon whether the field reports its text, which it requires
// outside terminals, as macOS requires a readable AXValue. A non-empty `commitToken` lets the
// daemon commit the translation back through this addon.
int sendTrigger(bool surroundingText, const std::string &commitToken) {
    std::string triggerRequest = std::string("{\"command\":\"triple_space\",\"surrounding_text\":") +
                                 (surroundingText ? "true" : "false");
    if (!commitToken.empty()) {
        triggerRequest += ",\"commit_token\":\"" + commitToken + "\"";
    }
    triggerRequest += "}\n";
    sockaddr_un address;
    if (const int error = socketAddress(runtimeSocketPath("control.sock"), address)) {
        return error;
    }

    const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return errno;
    }
    int error = 0;
    if (::connect(fd, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
        error = errno;
    } else if (::send(fd, triggerRequest.data(), triggerRequest.size(), MSG_NOSIGNAL) !=
               static_cast<ssize_t>(triggerRequest.size())) {
        error = errno ? errno : EIO;
    }
    ::close(fd);
    return error;
}

// Shape of the text around the cursor. The draft itself never reaches the journal.
std::string describeSurroundingText(const fcitx::InputContext &ic) {
    const auto &surrounding = ic.surroundingText();
    if (!surrounding.isValid()) {
        return "surrounding=none";
    }
    const auto &text = surrounding.text();
    const auto cursor = surrounding.cursor();
    const auto offset = static_cast<size_t>(fcitx::utf8::ncharByteLength(text.begin(), cursor));
    size_t spacesBefore = 0;
    while (spacesBefore < offset && text[offset - spacesBefore - 1] == ' ') {
        ++spacesBefore;
    }
    std::ostringstream description;
    description << "surrounding_chars=" << fcitx::utf8::length(text) << " cursor=" << cursor
                << " anchor=" << surrounding.anchor() << " spaces_before_cursor=" << spacesBefore
                << " chars_after_cursor=" << fcitx::utf8::length(text, offset, text.size());
    return description.str();
}

class NoTypeAddon : public fcitx::AddonInstance {
public:
    explicit NoTypeAddon(fcitx::Instance *instance) : instance_(instance) {
        watchers_.push_back(instance->watchEvent(
            fcitx::EventType::InputContextKeyEvent, fcitx::EventWatcherPhase::PreInputMethod,
            [this](fcitx::Event &event) {
                guarded([&] { beforeInputMethod(static_cast<fcitx::KeyEvent &>(event)); });
            }));
        watchers_.push_back(instance->watchEvent(
            fcitx::EventType::InputContextKeyEvent, fcitx::EventWatcherPhase::PostInputMethod,
            [this](fcitx::Event &event) {
                guarded([&] { afterInputMethod(static_cast<fcitx::KeyEvent &>(event)); });
            }));
        for (auto type : {fcitx::EventType::InputContextFocusOut,
                          fcitx::EventType::InputContextReset,
                          fcitx::EventType::InputContextDestroyed}) {
            watchers_.push_back(instance->watchEvent(
                type, fcitx::EventWatcherPhase::Default, [this, type](fcitx::Event &event) {
                    guarded([&] {
                        auto *ic = static_cast<fcitx::InputContextEvent &>(event).inputContext();
                        // A context that lost focus may only take the translation back if the
                        // user returns to it before it arrives; drop the token instead.
                        if (type != fcitx::EventType::InputContextReset &&
                            ic == commitContext_.get()) {
                            commitToken_.clear();
                            commitContext_.unwatch();
                        }
                        // Only compares the pointer: a destroyed context is never dereferenced.
                        if (ic == inputContext_) {
                            NOTYPE_DEBUG() << "forget after event 0x" << std::hex
                                           << static_cast<uint32_t>(type);
                            forget();
                        }
                    });
                }));
        }
    }

    ~NoTypeAddon() override {
        if (!listenPath_.empty()) {
            ::unlink(listenPath_.c_str());
        }
    }

private:
    struct CommitConnection {
        fcitx::UnixFD fd;
        std::string payload;
        std::unique_ptr<fcitx::EventSourceIO> event;
        bool finished = false;
    };

    template <typename Body>
    static void guarded(Body &&body) {
        try {
            body();
        } catch (...) {
        }
    }

    static bool isPlainSpace(const fcitx::KeyEvent &event) {
        return event.key().check(FcitxKey_space) &&
               !event.rawKey().states().test(fcitx::KeyState::Virtual);
    }

    // Every key reaches this phase. A Space is only counted once it also reaches
    // PostInputMethod, so a Space the input method consumed (Rime committing a candidate)
    // breaks the sequence instead of extending it.
    void beforeInputMethod(const fcitx::KeyEvent &event) {
        if (event.inputContext() != inputContext_) {
            forget();
            inputContext_ = event.inputContext();
        }
        if (awaitingSpace_) {
            awaitingSpace_ = false;
            detector_.reset();
        }
        if (event.isRelease()) {
            if (event.rawKey().sym() == FcitxKey_space) {
                spaceDown_ = false;
            }
            return;
        }

        const bool space = isPlainSpace(event);
        // Wayland marks repeats; other frontends only show a press without a release.
        const bool repeat =
            event.rawKey().states().test(fcitx::KeyState::Repeat) || (space && spaceDown_);
        if (space) {
            spaceDown_ = true;
        }
        if (!space || repeat) {
            detector_.reset();
            return;
        }
        awaitingSpace_ = true;
    }

    void afterInputMethod(const fcitx::KeyEvent &event) {
        if (event.isRelease() || !awaitingSpace_ || event.inputContext() != inputContext_) {
            return;
        }
        awaitingSpace_ = false;
        auto &ic = *event.inputContext();
        if (ic.capabilityFlags().testAny(fcitx::CapabilityFlag::PasswordOrSensitive)) {
            detector_.reset();
            return;
        }
        const auto result =
            detector_.consume(true, false, notype::TripleSpaceDetector::Clock::now());
        if (result == notype::TripleSpaceResult::Armed) {
            NOTYPE_DEBUG() << "armed program=" << ic.program();
        } else if (result == notype::TripleSpaceResult::Triggered) {
            // The third Space still reaches the client; the daemon removes all three.
            commitToken_.clear();
            commitContext_.unwatch();
            if (ensureListening()) {
                commitToken_ = newToken();
                commitContext_ = ic.watch();
            }
            const int error = sendTrigger(ic.surroundingText().isValid(), commitToken_);
            NOTYPE_INFO() << "triple-space program=" << ic.program()
                          << " frontend=" << ic.frontendName() << " caps=0x" << std::hex
                          << ic.capabilityFlags().toInteger() << std::dec << " "
                          << describeSurroundingText(ic)
                          << " sent=" << (error ? std::strerror(error) : "ok");
        }
    }

    void forget() {
        inputContext_ = nullptr;
        detector_.reset();
        awaitingSpace_ = false;
        spaceDown_ = false;
    }

    static std::string newToken() {
        std::random_device random;
        const uint64_t value = (static_cast<uint64_t>(random()) << 32) | random();
        char token[17];
        std::snprintf(token, sizeof(token), "%016llx", static_cast<unsigned long long>(value));
        return token;
    }

    // Binds the commit socket on the first trigger, once the daemon has created its runtime
    // directory. Without it the daemon pastes through the clipboard as before.
    bool ensureListening() {
        if (listenEvent_) {
            return true;
        }
        const std::string path = runtimeSocketPath("fcitx5.sock");
        sockaddr_un address;
        if (socketAddress(path, address) != 0) {
            return false;
        }
        fcitx::UnixFD fd = fcitx::UnixFD::own(
            ::socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0));
        if (!fd.isValid()) {
            return false;
        }
        // A previous fcitx5 process may have left its socket behind.
        ::unlink(path.c_str());
        if (::bind(fd.fd(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0 ||
            ::chmod(path.c_str(), 0600) != 0 || ::listen(fd.fd(), 4) != 0) {
            NOTYPE_INFO() << "commit socket unavailable: " << std::strerror(errno);
            ::unlink(path.c_str());
            return false;
        }
        listenPath_ = path;
        listenFd_ = std::move(fd);
        listenEvent_ = instance_->eventLoop().addIOEvent(
            listenFd_.fd(), fcitx::IOEventFlag::In, [this](fcitx::EventSourceIO *, int, auto) {
                guarded([&] { acceptCommitConnections(); });
                return true;
            });
        return true;
    }

    void acceptCommitConnections() {
        // Finished connections disabled their own event source; free them outside its callback.
        connections_.remove_if([](const CommitConnection &connection) { return connection.finished; });
        while (true) {
            fcitx::UnixFD fd = fcitx::UnixFD::own(
                ::accept4(listenFd_.fd(), nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC));
            if (!fd.isValid()) {
                return;
            }
            if (connections_.size() >= kMaxCommitConnections) {
                continue;
            }
            auto &connection = connections_.emplace_back();
            connection.fd = std::move(fd);
            connection.event = instance_->eventLoop().addIOEvent(
                connection.fd.fd(), fcitx::IOEventFlag::In,
                [this, &connection](fcitx::EventSourceIO *, int, auto) {
                    guarded([&] { readCommitConnection(connection); });
                    return true;
                });
        }
    }

    // The daemon writes one request and shuts down its write side; reply once it is complete.
    void readCommitConnection(CommitConnection &connection) {
        if (connection.finished) {
            return;
        }
        char buffer[4096];
        while (true) {
            const ssize_t count = ::read(connection.fd.fd(), buffer, sizeof(buffer));
            if (count > 0) {
                connection.payload.append(buffer, static_cast<size_t>(count));
                if (connection.payload.size() > notype::kMaxCommitBytes + 64) {
                    finishCommitConnection(connection, "error");
                    return;
                }
                continue;
            }
            if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
                return;
            }
            finishCommitConnection(connection, count == 0 ? commit(connection.payload) : "error");
            return;
        }
    }

    void finishCommitConnection(CommitConnection &connection, std::string_view reply) {
        const std::string line = std::string(reply) + "\n";
        (void)::send(connection.fd.fd(), line.data(), line.size(), MSG_NOSIGNAL);
        connection.event->setEnabled(false);
        connection.fd.reset();
        connection.finished = true;
    }

    // `ok` once the text went to the client, `stale` when the trigger's context no longer has
    // focus, `error` for a malformed request. Only `ok` means anything was committed.
    std::string_view commit(const std::string &payload) {
        const auto request = notype::parseCommitRequest(payload);
        if (!request || !fcitx::utf8::validate(request->text)) {
            return "error";
        }
        auto *ic = commitContext_.get();
        if (commitToken_.empty() || request->token != commitToken_ || !ic || !ic->hasFocus()) {
            NOTYPE_INFO() << "commit refused: stale input context";
            return "stale";
        }
        commitToken_.clear();
        commitContext_.unwatch();
        ic->commitString(request->text);
        NOTYPE_INFO() << "committed translation program=" << ic->program()
                      << " chars=" << fcitx::utf8::length(request->text);
        return "ok";
    }

    fcitx::Instance *instance_;
    std::vector<std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>>> watchers_;
    fcitx::InputContext *inputContext_ = nullptr;
    notype::TripleSpaceDetector detector_;
    bool awaitingSpace_ = false;
    bool spaceDown_ = false;
    std::string commitToken_;
    fcitx::TrackableObjectReference<fcitx::InputContext> commitContext_;
    std::string listenPath_;
    fcitx::UnixFD listenFd_;
    std::unique_ptr<fcitx::EventSourceIO> listenEvent_;
    // A list keeps each connection's address stable for its event callback.
    std::list<CommitConnection> connections_;
};

class NoTypeAddonFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new NoTypeAddon(manager->instance());
    }
};

} // namespace

FCITX_ADDON_FACTORY_V2(notype, NoTypeAddonFactory);
