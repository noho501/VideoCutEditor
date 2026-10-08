import Foundation
import Testing
@testable import VideoCutEditor

@Test func normalizedCutsClampSortAndMerge() async throws {
    let input = [
        VideoCut(startTime: 20, endTime: 25),
        VideoCut(startTime: -2, endTime: 2),
        VideoCut(startTime: 1, endTime: 5),
        VideoCut(startTime: 24, endTime: 40),
        VideoCut(startTime: 8, endTime: 8)
    ]

    let result = VideoCutValidator.normalizedCuts(input, duration: 30)

    #expect(result.count == 2)
    #expect(result[0] == VideoCut(startTime: 0, endTime: 5))
    #expect(result[1] == VideoCut(startTime: 20, endTime: 30))
}

@Test func selectedCutsRemainTheExportRanges() async throws {
    let cuts = [
        VideoCut(startTime: 15, endTime: 18),
        VideoCut(startTime: 5, endTime: 10)
    ]

    let ranges = VideoCutValidator.normalizedCuts(cuts, duration: 20)

    #expect(ranges == [
        VideoCut(startTime: 5, endTime: 10),
        VideoCut(startTime: 15, endTime: 18)
    ])
}

@Test func clampedCutsPreserveDistinctSourceOfTruthEntries() {
    let cuts = [
        VideoCut(startTime: 5, endTime: 10),
        VideoCut(startTime: 8, endTime: 12)
    ]

    let result = VideoCutValidator.clampedCuts(cuts, duration: 20)

    #expect(result.count == 2)
    #expect(result == cuts)
}

@Test func normalizedCutsHandleAdjacentAndNonFiniteValues() {
    let cuts = [
        VideoCut(startTime: 0, endTime: 1),
        VideoCut(startTime: 1, endTime: 2),
        VideoCut(startTime: .nan, endTime: 5),
        VideoCut(startTime: 9, endTime: 20)
    ]

    let result = VideoCutValidator.normalizedCuts(cuts, duration: 10)

    #expect(result == [
        VideoCut(startTime: 0, endTime: 2),
        VideoCut(startTime: 9, endTime: 10)
    ])
}

@Test func clampedCutsSupportMoreThanThirtyDistinctEntries() {
    let cuts = (0..<35).map {
        VideoCut(startTime: Double($0), endTime: Double($0) + 0.75)
    }

    let result = VideoCutValidator.clampedCuts(cuts, duration: 60)

    #expect(result.count == 35)
    #expect(result.first == cuts.first)
    #expect(result.last == cuts.last)
}

@Test func timelineCoordinateConversionsRemainStableForLongVideo() {
    let coordinateSpace = TimelineCoordinateSpace(
        duration: 3_600,
        pointsPerSecond: 24,
        viewportWidth: 390
    )
    let time = 2_245.375

    let x = coordinateSpace.xPosition(for: time)
    let offset = coordinateSpace.contentOffset(for: time)

    #expect(abs(coordinateSpace.time(forXPosition: x) - time) < 0.000_001)
    #expect(abs(coordinateSpace.time(forContentOffset: offset) - time) < 0.000_001)
    #expect(coordinateSpace.contentWidth == 86_400)
}

@Test func temporaryFilePathAndCleanup() async throws {
    let outputURL = try VideoCutFileManager.makeOutputURL()
    #expect(outputURL.path.contains("/VideoCutEditor/"))
    #expect(outputURL.pathExtension == "mp4")

    let data = Data("test".utf8)
    try data.write(to: outputURL)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    VideoCutFileManager.remove(outputURL)
    #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)

    let anotherURL = try VideoCutFileManager.makeOutputURL()
    try data.write(to: anotherURL)
    VideoCutFileManager.clearTemporaryFiles()
    #expect(FileManager.default.fileExists(atPath: anotherURL.path) == false)
}

@Test func cleanupRejectsFilesOutsideManagedDirectory() throws {
    let outsideURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("unrelated-\(UUID().uuidString).tmp")
    try Data("keep".utf8).write(to: outsideURL)
    defer { try? FileManager.default.removeItem(at: outsideURL) }

    let result = VideoCutFileManager.remove(outsideURL)

    if case .success = result {
        Issue.record("Expected removal outside the managed directory to fail")
    }
    #expect(FileManager.default.fileExists(atPath: outsideURL.path))
}
