extension SaverScene {
    static let all: [SaverScene] = [
        campfire, neonCity, neonLines, retroGrid, orbRunner, aurora, deepSea, starfield, lavaLamp, fireflies,
    ]

    /// The scene with this name, or the first if there's none.
    static func named(_ name: String) -> SaverScene { all.first { $0.name == name } ?? all[0] }
}
