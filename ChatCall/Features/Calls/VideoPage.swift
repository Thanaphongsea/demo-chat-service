nonisolated struct VideoPage {
  struct Tile: Identifiable {
    let user: User
    let isVideoEnabled: Bool
    var id: UserID { user.id }
  }
  let localUser: User
  private(set) var index = 0
  private var remotes: [User] = []
  private var audioOnlyIDs: Set<UserID> = []
  var pageCount: Int { max(1, (remotes.count + 2) / 3) }
  var tiles: [Tile] {
    ([localUser] + Array(remotes.dropFirst(index * 3).prefix(3))).map {
      Tile(user: $0, isVideoEnabled: !audioOnlyIDs.contains($0.id))
    }
  }
  mutating func update(participants: [User], audioOnlyIDs: Set<UserID> = []) {
    var remaining = participants.filter { $0.id != localUser.id }
    remotes = remotes.compactMap { user in
      guard let index = remaining.firstIndex(where: { $0.id == user.id }) else { return nil }
      return remaining.remove(at: index)
    }
    for user in remaining where !remotes.contains(where: { $0.id == user.id }) {
      remotes.append(user)
    }
    self.audioOnlyIDs = audioOnlyIDs
    index = min(index, pageCount - 1)
  }
  mutating func next() { index = min(index + 1, pageCount - 1) }
  mutating func previous() { index = max(0, index - 1) }
}
