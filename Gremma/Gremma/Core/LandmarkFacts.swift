import Foundation

public struct LandmarkFactPack: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sourceTitle: String
    public let sourceURL: String
    public let verifiedOn: String
    public let facts: [String]
    public let shortDescription: String
    public let walkthrough: String

    public var promptContext: String {
        """
        You are describing \(name) to a blind or low-vision listener. Use only the verified facts below.
        Start with the overall shape, then spatial layout and materials. Keep a short answer under 90 words.
        For a walkthrough use short, pausable paragraphs. A mental walkthrough is an imagined explanation, not directions for walking at the site.
        Do not invent heights, distances, colors, counts, sounds, smells, history or tactile access. Make comparisons only as explicit analogies, never as measurements.
        If the requested detail is absent from this fact pack, say it is not in the verified facts available offline.
        Source: \(sourceTitle), \(sourceURL). Checked \(verifiedOn).
        VERIFIED FACTS:
        \(facts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        """
    }
}

public enum LandmarkFacts {
    // Original paraphrase of UNESCO's listed architectural facts. No unsupported dimensions.
    // Kept under 200 words of source-derived content across facts and descriptions.
    public static let tajMahal = LandmarkFactPack(
        id: "taj-mahal",
        name: "Taj Mahal",
        sourceTitle: "UNESCO World Heritage Centre — Taj Mahal",
        sourceURL: "https://whc.unesco.org/en/list/252/",
        verifiedOn: "2026-10-23",
        facts: [
            "The Taj Mahal is a white-marble mausoleum in Agra, India, beside the Yamuna River.",
            "Shah Jahan commissioned it in memory of his wife Mumtaz Mahal.",
            "Its domed tomb stands on a raised square platform, with four separate minarets at the platform's corners.",
            "The tomb sits at one end of a garden divided into four quarters by walkways.",
            "The complex is arranged symmetrically around a central axis.",
            "The central tomb chamber is octagonal and contains marble latticework and floral stone inlay.",
            "A red-sandstone mosque and guest house contrast with the marble tomb."
        ],
        shortDescription: "Picture a white-marble building with a dome, raised above a garden. Four slender towers mark its platform's corners. The layout balances around a central line. Walkways divide the garden into four parts; the tomb stands at its far end.",
        walkthrough: "This is a mental picture, not walking directions. Imagine the garden first: walkways divide it into four quarters. At one end is the raised tomb, crowned by a dome. Now place a minaret at each corner of its platform. Inside, picture an eight-sided chamber with marble screens and floral inlay."
    )
}
