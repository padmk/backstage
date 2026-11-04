// Home has no scripting dictionary, so it carries what is known about its window.

let homeKnowledge = AppKnowledge(
  bundleId: "com.apple.Home", name: "Home", summary: "Hints for controlling accessories through the window",
  hints: [
    "Accessory tiles are collapsed groups; background clicks on them are ignored. Open one with press action \"Name:More Controls\nTarget:0x0\nSelector:(null)\", copied exactly from the tile's actions.",
    "In a light's controls, the large \"Light\" slider takes Increment and Decrement; the brightness field only takes press.",
  ],
  pitfalls: [
    "Pressing a favorite color also sets the brightness stored with it.",
    "A custom color has no readable value until it is added to favorites; the favorite's id carries its hex value.",
    "Favorites cannot be removed through accessibility.",
  ])
