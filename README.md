# Klar-sjekk

*Har du med deg alt før neste battleground?*

En liten addon for **World of Warcraft Forever** som passer på at du har med deg det du trenger før PvP:
potions, healthstones, bandasjer, PvP-trinketen, buffer og gift på våpenet. Én liten knapp på skjermen viser
hvor mange ting som mangler, og den lyser rolig opp når det faktisk gjelder.

- **Du lager lista selv med dra og slipp.** Dra en ting fra baggen eller en spell fra spellboken inn i vinduet.
  En ting i baggen sjekkes på antall, utstyr på at det er på deg, en spell på at buffen er på.
  Gift og olje på våpenet har egne knapper.
- **Forslag fra baggen:** trinketene du har på deg og forbruksvarene i baggen vises som forslag – ett klikk, så står
  de på lista. «Vis alt» tar med resten av baggen.
- **Juster:** musehjul på en rad endrer antall (eller hvor mange minutter som skal være igjen på en buff),
  Shift = 5 om gangen. Høyreklikk på en eliksir bytter mellom «antall i baggen» og «buffen er på».
- **Fjern og flytt:** dra en rad ut av vinduet for å fjerne den (`/klar angre` angrer), opp eller ned for å bytte plass.
- Lista lagres per karakter.

## Varselet – uten å mase

Ingen blinking. En myk, oransje ring rundt knappen pulserer rolig – og bare når noe mangler **og** det gjelder:
når du står i BG-kø, når køen spretter, og når du kommer inn i en BG. Den pulserer i 30 sekunder og lyser
deretter svakt til du har ordnet det. Åpner du lista, roer den seg med en gang.

- **Høyreklikk** på knappen = «ikke nå» – mørk til neste kø eller BG.
- **Aldri i kamp.**
- Valgfritt: lys også når PvP-flagget er på (world PvP), og én lyd når køen spretter. Begge er av som standard.

## Installere

**Enklest – med automatiske oppdateringer:** bruk [WowUp](https://wowup.io) (gratis).
1. Åpne WowUp og velg World of Warcraft Forever.
2. *Get Addons* → *Install from URL* → lim inn `https://github.com/Romkapsel/klarsjekk` → *Install*.
3. WowUp sjekker selv etter nye versjoner og oppdaterer med ett klikk.

**For hånd:** last ned `Klarsjekk-x.y.z.zip` under [Releases](https://github.com/Romkapsel/klarsjekk/releases),
pakk den ut i `World of Warcraft\_classic_beta_\Interface\AddOns\` (mappen skal hete `Klarsjekk`) og start spillet på nytt.

## Kommandoer

- `/klar` – åpne eller lukke lista
- `/klar test` – se hvordan varselet ser ut (30 sekunder puls, så svakt lys)
- `/klar angre` – få tilbake det du sist fjernet
- `/klar reset` – flytt knappen tilbake til start

Knappen flyttes ved å dra i den.

## Godt å vite

- Addonen gjør ingenting for deg – den bare viser hva som mangler. Den leser buffer og bagger bare utenfor kamp;
  i kamp er de «hemmelige» for addons i WoW Forever.
- Lisens: MIT.
