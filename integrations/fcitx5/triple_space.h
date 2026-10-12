// Triple-Space sequence detector. Port of TripleSpaceSequenceDetector in
// Sources/NoType/Services/TripleSpaceTriggerService.swift; no fcitx5 dependency.
#ifndef NOTYPE_FCITX5_TRIPLE_SPACE_H
#define NOTYPE_FCITX5_TRIPLE_SPACE_H

#include <chrono>
#include <optional>

namespace notype {

enum class TripleSpaceResult { Pending, Armed, Triggered };

class TripleSpaceDetector {
public:
    using Clock = std::chrono::steady_clock;

    explicit TripleSpaceDetector(
        Clock::duration maximumDuration = std::chrono::seconds(1))
        : maximumDuration_(maximumDuration) {}

    // Feed every key press; anything but a plain, non-repeated Space resets.
    TripleSpaceResult consume(bool isPlainSpace, bool isRepeat,
                              Clock::time_point timestamp) {
        if (!isPlainSpace || isRepeat) {
            reset();
            return TripleSpaceResult::Pending;
        }

        if (firstTimestamp_ && timestamp >= *firstTimestamp_ &&
            timestamp - *firstTimestamp_ <= maximumDuration_) {
            ++spaceCount_;
        } else {
            firstTimestamp_ = timestamp;
            spaceCount_ = 1;
        }

        switch (spaceCount_) {
        case 2:
            return TripleSpaceResult::Armed;
        case 3:
            reset();
            return TripleSpaceResult::Triggered;
        default:
            return TripleSpaceResult::Pending;
        }
    }

    void reset() {
        firstTimestamp_.reset();
        spaceCount_ = 0;
    }

private:
    Clock::duration maximumDuration_;
    std::optional<Clock::time_point> firstTimestamp_;
    int spaceCount_ = 0;
};

} // namespace notype

#endif
