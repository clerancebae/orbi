import Foundation
import SwiftData

@Model
final class WaterLog {
    var id: UUID
    var timestamp: Date
    var amountMl: Int

    init(id: UUID = UUID(), timestamp: Date = .now, amountMl: Int) {
        self.id = id
        self.timestamp = timestamp
        self.amountMl = amountMl
    }
}
