// Commit request framing; the Rust writer is covered by linux/src/fcitx.rs tests.
#include "commit_request.h"

#include <cstdio>
#include <cstdlib>
#include <string>

using notype::parseCommitRequest;

namespace {

int failures = 0;

void expect(bool condition, const char *what, int line) {
    if (!condition) {
        std::fprintf(stderr, "line %d: %s\n", line, what);
        ++failures;
    }
}

#define EXPECT(condition) expect((condition), #condition, __LINE__)

void parsesTokenAndExactText() {
    const auto request = parseCommitRequest("0123abcd 12\nHello\nworld!");
    EXPECT(request.has_value());
    EXPECT(request && request->token == "0123abcd");
    EXPECT(request && request->text == "Hello\nworld!");

    const auto utf8 = parseCommitRequest("t 6\n你好");
    EXPECT(utf8 && utf8->text == "你好");
}

void rejectsTruncatedOrMalformedRequests() {
    EXPECT(!parseCommitRequest("t 6\nHello"));
    EXPECT(!parseCommitRequest("t 4\nHello"));
    EXPECT(!parseCommitRequest("t 0\n"));
    EXPECT(!parseCommitRequest("t 5"));
    EXPECT(!parseCommitRequest(" 5\nHello"));
    EXPECT(!parseCommitRequest("t\nHello"));
    EXPECT(!parseCommitRequest("t 5x\nHello"));
    EXPECT(!parseCommitRequest("t -5\nHello"));
    EXPECT(!parseCommitRequest(""));
}

void rejectsOversizedText() {
    const std::string text(notype::kMaxCommitBytes + 1, 'a');
    EXPECT(!parseCommitRequest("t " + std::to_string(text.size()) + "\n" + text));
    const std::string limit(notype::kMaxCommitBytes, 'a');
    EXPECT(parseCommitRequest("t " + std::to_string(limit.size()) + "\n" + limit).has_value());
}

} // namespace

int main() {
    parsesTokenAndExactText();
    rejectsTruncatedOrMalformedRequests();
    rejectsOversizedText();
    if (failures) {
        return EXIT_FAILURE;
    }
    std::puts("commit_request: ok");
    return EXIT_SUCCESS;
}
