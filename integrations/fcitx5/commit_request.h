// Commit request framing shared with linux/src/fcitx.rs; no fcitx5 dependency.
//   "<token> <byte length>\n<UTF-8 text>"
// The length lets the addon refuse a request cut short, so it never commits partial text.
#ifndef NOTYPE_FCITX5_COMMIT_REQUEST_H
#define NOTYPE_FCITX5_COMMIT_REQUEST_H

#include <charconv>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace notype {

constexpr std::size_t kMaxCommitBytes = 64 * 1024;

struct CommitRequest {
    std::string token;
    std::string text;
};

inline std::optional<CommitRequest> parseCommitRequest(std::string_view payload) {
    const auto newline = payload.find('\n');
    if (newline == std::string_view::npos) {
        return std::nullopt;
    }
    const auto header = payload.substr(0, newline);
    const auto space = header.find(' ');
    if (space == 0 || space == std::string_view::npos) {
        return std::nullopt;
    }
    const auto lengthText = header.substr(space + 1);
    std::size_t length = 0;
    const auto [end, error] =
        std::from_chars(lengthText.data(), lengthText.data() + lengthText.size(), length);
    const auto text = payload.substr(newline + 1);
    if (error != std::errc() || end != lengthText.data() + lengthText.size() || length == 0 ||
        length > kMaxCommitBytes || text.size() != length) {
        return std::nullopt;
    }
    return CommitRequest{std::string(header.substr(0, space)), std::string(text)};
}

} // namespace notype

#endif
