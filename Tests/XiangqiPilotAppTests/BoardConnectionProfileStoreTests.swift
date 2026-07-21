import CoreGraphics
import Foundation
import Testing
@testable import XiangqiPilotApp

@Suite struct BoardConnectionProfileStoreTests {
    @Test func normalizedGeometryRestoresAUsableCalibration() throws {
        let geometry = try sampleGeometry()
        let calibration = try geometry.makeCalibration(
            imageSize: CGSize(width: 1_000, height: 800),
            windowFrame: CGRect(x: 240, y: 120, width: 1_000, height: 800)
        )

        #expect(calibration.imagePoint(for: try XiangqiGridPoint(file: 0, rank: 0)) == CGPoint(x: 100, y: 80))
        #expect(calibration.imagePoint(for: try XiangqiGridPoint(file: 8, rank: 9)) == CGPoint(x: 900, y: 720))
        #expect(try calibration.globalScreenPoint(for: XiangqiGridPoint(file: 4, rank: 4)) == CGPoint(x: 740, y: 484.44444444444446))
    }

    @Test func profileTargetRequiresEveryDeclaredIdentityToMatch() throws {
        let target = try BoardConnectionTarget(
            bundleIdentifier: "com.example.chess",
            windowTitleHint: "练习棋局",
            adapterIdentifier: "visual-only"
        )

        #expect(target.matchScore(for: BoardConnectionTargetContext(
            bundleIdentifier: "com.example.chess",
            windowTitle: "第 12 局 · 练习棋局",
            adapterIdentifier: "visual-only",
            gameIdentifier: "xiangqi"
        )) == 200)
        #expect(target.matchScore(for: BoardConnectionTargetContext(
            bundleIdentifier: "com.example.chess",
            windowTitle: "第 12 局 · 练习棋局",
            adapterIdentifier: "other",
            gameIdentifier: "xiangqi"
        )) == nil)
        #expect(target.matchScore(for: BoardConnectionTargetContext(
            bundleIdentifier: "com.other.client",
            windowTitle: "第 12 局 · 练习棋局",
            adapterIdentifier: "visual-only",
            gameIdentifier: "xiangqi"
        )) == nil)
    }

    @Test func storePersistsProfilesAndChoosesTheMostSpecificMatch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoardConnectionProfileStore(directoryURL: directory)
        let geometry = try sampleGeometry()

        let broad = try BoardConnectionProfile(
            name: "通用练习棋盘",
            target: try BoardConnectionTarget(bundleIdentifier: "com.example.chess"),
            geometry: geometry
        )
        let specific = try BoardConnectionProfile(
            name: "练习局",
            target: try BoardConnectionTarget(
                bundleIdentifier: "com.example.chess",
                windowTitleHint: "练习棋局",
                adapterIdentifier: "visual-only"
            ),
            geometry: geometry
        )

        _ = try await store.save(broad)
        _ = try await store.save(specific)

        let profiles = try await store.list()
        #expect(Set(profiles.map(\.id)) == Set([broad.id, specific.id]))
        let result = try await store.bestMatch(for: BoardConnectionTargetContext(
            bundleIdentifier: "com.example.chess",
            windowTitle: "第 12 局 · 练习棋局",
            adapterIdentifier: "visual-only",
            gameIdentifier: "xiangqi"
        ))
        #expect(result?.id == specific.id)
        #expect(try await store.bestMatch(for: BoardConnectionTargetContext(
            bundleIdentifier: "com.example.chess",
            windowTitle: "第 12 局 · 练习棋局",
            adapterIdentifier: "visual-only",
            gameIdentifier: "gomoku"
        )) == nil)
    }

    @Test func invalidGeometryAndAnonymousTargetAreRejected() throws {
        #expect(throws: BoardConnectionProfileError.missingTargetIdentity) {
            _ = try BoardConnectionTarget()
        }
        let point = try NormalizedBoardPoint(x: 0.5, y: 0.5)
        #expect(throws: BoardConnectionProfileError.degenerateGeometry) {
            _ = try NormalizedBoardGeometry(
                topLeft: point,
                topRight: point,
                bottomLeft: point,
                bottomRight: point
            )
        }
    }

    @Test func corruptProfileDataIsNotAcceptedOnLoad() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = BoardConnectionProfileStore(directoryURL: directory)
        let profile = try BoardConnectionProfile(
            name: "有效方案",
            target: try BoardConnectionTarget(bundleIdentifier: "com.example.chess"),
            geometry: try sampleGeometry()
        )
        let invalidJSON = """
        {
          "id":"\(profile.id.uuidString)",
          "name":"",
          "target":{"bundleIdentifier":"com.example.chess","windowTitleHint":null,"adapterIdentifier":null},
          "geometry":{
            "topLeft":{"x":0.1,"y":0.1},
            "topRight":{"x":0.9,"y":0.1},
            "bottomLeft":{"x":0.1,"y":0.9},
            "bottomRight":{"x":0.9,"y":0.9}
          },
          "gameIdentifier":"xiangqi",
          "orientation":"redAtBottom",
          "createdAt":"2026-07-21T00:00:00Z",
          "updatedAt":"2026-07-21T00:00:00Z"
        }
        """
        try Data(invalidJSON.utf8).write(
            to: directory.appendingPathComponent(profile.id.uuidString).appendingPathExtension("json")
        )

        await #expect(throws: BoardConnectionProfileError.self) {
            _ = try await store.load(id: profile.id)
        }
        #expect(try await store.list().isEmpty)
    }

    private func sampleGeometry() throws -> NormalizedBoardGeometry {
        try NormalizedBoardGeometry(
            topLeft: try NormalizedBoardPoint(x: 0.1, y: 0.1),
            topRight: try NormalizedBoardPoint(x: 0.9, y: 0.1),
            bottomLeft: try NormalizedBoardPoint(x: 0.1, y: 0.9),
            bottomRight: try NormalizedBoardPoint(x: 0.9, y: 0.9)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("xiangqi-pilot-connection-profile-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
