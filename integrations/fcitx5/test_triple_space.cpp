// Mirrors the TripleSpaceSequenceDetector cases in Tests/NoTypeTests/NoTypeTests.swift.
#include "triple_space.h"

#include <cstdio>
#include <cstdlib>

using notype::TripleSpaceDetector;
using notype::TripleSpaceResult;

namespace {

int failures = 0;

TripleSpaceDetector::Clock::time_point at(double seconds) {
    return TripleSpaceDetector::Clock::time_point(
        std::chrono::duration_cast<TripleSpaceDetector::Clock::duration>(
            std::chrono::duration<double>(seconds)));
}

void expect(TripleSpaceResult actual, TripleSpaceResult expected, int line) {
    if (actual != expected) {
        std::fprintf(stderr, "line %d: got %d, want %d\n", line,
                     static_cast<int>(actual), static_cast<int>(expected));
        ++failures;
    }
}

#define EXPECT(call, result) expect((call), TripleSpaceResult::result, __LINE__)

void triggersOnThreeSpacesWithinOneSecond() {
    TripleSpaceDetector detector;
    EXPECT(detector.consume(true, false, at(10.0)), Pending);
    EXPECT(detector.consume(true, false, at(10.4)), Armed);
    EXPECT(detector.consume(true, false, at(10.9)), Triggered);
}

void restartsAfterTimeoutOtherKeysAndRepeats() {
    TripleSpaceDetector detector;
    EXPECT(detector.consume(true, false, at(20.0)), Pending);
    EXPECT(detector.consume(true, false, at(20.5)), Armed);
    EXPECT(detector.consume(true, false, at(21.1)), Pending);

    EXPECT(detector.consume(false, false, at(21.2)), Pending);
    EXPECT(detector.consume(true, false, at(21.3)), Pending);
    EXPECT(detector.consume(true, true, at(21.4)), Pending);
    EXPECT(detector.consume(true, false, at(21.5)), Pending);
    EXPECT(detector.consume(true, false, at(21.7)), Armed);
    EXPECT(detector.consume(true, false, at(21.9)), Triggered);
}

void startsOverAfterTriggering() {
    TripleSpaceDetector detector;
    EXPECT(detector.consume(true, false, at(1.0)), Pending);
    EXPECT(detector.consume(true, false, at(1.1)), Armed);
    EXPECT(detector.consume(true, false, at(1.2)), Triggered);
    EXPECT(detector.consume(true, false, at(1.3)), Pending);
}

} // namespace

int main() {
    triggersOnThreeSpacesWithinOneSecond();
    restartsAfterTimeoutOtherKeysAndRepeats();
    startsOverAfterTriggering();
    if (failures) {
        return EXIT_FAILURE;
    }
    std::puts("triple_space: ok");
    return EXIT_SUCCESS;
}
