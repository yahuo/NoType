// NoType fcitx5 addon: three quick Spaces in any input context ask the NoType daemon to
// translate the draft. Linux counterpart of TripleSpaceTriggerService.swift; it runs inside
// fcitx5, so it only detects the trigger and never blocks or throws into the event loop.

#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/instance.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "triple_space.h"

namespace {

FCITX_DEFINE_LOG_CATEGORY(notypeLog, "notype");
#define NOTYPE_INFO() FCITX_LOGC(notypeLog, Info)
#define NOTYPE_DEBUG() FCITX_LOGC(notypeLog, Debug)

// Writes one control request and closes without reading the reply. Returns 0 or an errno.
// `surroundingText` tells the daemon whether the field reports its text, which it requires
// outside terminals, as macOS requires a readable AXValue.
int sendTrigger(bool surroundingText) {
    const std::string_view triggerRequest =
        surroundingText ? "{\"command\":\"triple_space\",\"surrounding_text\":true}\n"
                        : "{\"command\":\"triple_space\",\"surrounding_text\":false}\n";
    const char *runtimeDir = std::getenv("XDG_RUNTIME_DIR");
    if (!runtimeDir || !*runtimeDir) {
        return ENOENT;
    }
    const std::string path = std::string(runtimeDir) + "/notype/control.sock";
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) {
        return ENAMETOOLONG;
    }
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);

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
    explicit NoTypeAddon(fcitx::Instance *instance) {
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
                        // Only compares the pointer: a destroyed context is never dereferenced.
                        if (static_cast<fcitx::InputContextEvent &>(event).inputContext() ==
                            inputContext_) {
                            NOTYPE_DEBUG() << "forget after event 0x" << std::hex
                                           << static_cast<uint32_t>(type);
                            forget();
                        }
                    });
                }));
        }
    }

private:
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
            const int error = sendTrigger(ic.surroundingText().isValid());
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

    std::vector<std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>>> watchers_;
    fcitx::InputContext *inputContext_ = nullptr;
    notype::TripleSpaceDetector detector_;
    bool awaitingSpace_ = false;
    bool spaceDown_ = false;
};

class NoTypeAddonFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new NoTypeAddon(manager->instance());
    }
};

} // namespace

FCITX_ADDON_FACTORY_V2(notype, NoTypeAddonFactory);
