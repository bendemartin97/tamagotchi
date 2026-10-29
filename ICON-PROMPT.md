# Icon-Prompt

Für Midjourney, DALL·E, Ideogram, Firefly oder ähnliche Generatoren. Das Ergebnis als 1024×1024-PNG speichern und mit
`tools/icon.sh icon.png` zu `AppIcon.icns` machen.

## Hauptprompt (Englisch, funktioniert in den meisten Generatoren am besten)

```
macOS app icon, rounded square (squircle) with a soft deep-plum to midnight-violet gradient background, a cute chunky
pixel-art creature in the center: a boxy terracotta-orange blob with four short stubby legs, two tiny side arms,
small black pixel eyes happily squinting, pink pixel blush cheeks, a tiny satisfied mouth. It wears a glowing mint-green
pixel checkmark floating above its head like a halo. Around it, three tiny companion pixel pets in teal, lavender
and butter-yellow peek in from the edges, each with a different accessory (a cap, round glasses, headphones), as if
they are its team of little agents. Subtle long soft shadow under the creature, faint glow behind it, crisp pixel
edges, modern Apple Big Sur icon style, gentle depth and lighting on the squircle but the creature stays true
pixel art, playful but premium, centered composition, no text, no letters, 1024x1024
```

## Variante: nur das Haustier, ruhiger

```
minimal macOS app icon, squircle with a smooth dark aubergine gradient, one cute pixel-art terracotta creature with
four stubby legs and tiny arms, closed happy eyes and pink blush, a small mint-green pixel checkmark above it, soft
drop shadow, subtle inner glow on the squircle edge, clean Apple Big Sur style, pixel-perfect sprite, no text,
1024x1024
```

## Variante: Wächter-Look

```
macOS app icon, squircle with a night-sky indigo gradient and a few tiny pixel stars, a cute pixel-art terracotta
creature holding a tiny glowing lantern, watching over three sleeping mini pixel pets (teal, lavender, yellow) at its
feet, cozy and protective mood, warm lantern light on the creatures, crisp pixel art inside a polished Big Sur icon,
no text, 1024x1024
```

## Hinweise

- Midjourney: `--ar 1:1 --style raw --v 7` anhängen. Bei zu viel 3D-Glanz `--no 3d render, photorealistic` ergänzen.
- Farben passend zum Code: Fell `#D97757`, dunkler `#B85C40`, Haken `#4DB866`, Wangen `#FA8C99`.
- Der Platzhalter `icon.png` zeigt die Figur genau so, wie sie im Programm aussieht, und eignet sich als Bildvorlage
  („image prompt“).
