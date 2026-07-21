# Prestige regions & estates — extrinsic reference (NOT scored)

Curated reputation reference for **human judgment only**. Like `accolades`, none
of this is read by `candidate_prior` — reputation predicts *objective green
quality*, not *this user's affective fit*, and the history is far too sparse
(≈1 rated observation per farm) to estimate a region/estate prior. Surface it in
the 理性 section as context ("这批生豆客观顶尖 / 出自长期口碑庄园"), never as a
fit driver.

Reputation is inherently fuzzy and shifts year to year. This is a short curated
consensus list from a handful of sources + well-known competition results, not
an exhaustive or ranked ledger. When in doubt, say "widely regarded", not "the
best".

**Provenance of these judgments (confidence decreases down the list):**
1. **Primary / hard data** — competition results from Best of Panama
   (bestofpanama.org) and Cup of Excellence (cupofexcellence.org). "Won BoP 98
   pts", "won Ethiopia CoE 2021" are verifiable facts.
2. **Secondary** — coffee media + roaster blogs (see Sources). These describe
   *fame*; roaster blogs have a selling incentive, so treat as directional.
3. **My editorial judgment** — there is NO industry-canonical tiering. Which
   name lands in Tier 1 vs 2, and where the boundary sits, is a synthesis I made
   from (1) and (2). Competition facts are sourced; the *tiering* is a judgment
   call, flagged per-name and open to being overruled.

## Tier 1 — singular global prestige (very limited, high confidence)

**Inclusion bar (all three required)** — keeps Tier 1 small and uncontested:
1. **Sustained** top-competition results or world-championship-lot pedigree —
   not one good year.
2. **Cross-market name recognition** — known across many roasters/countries,
   not one importer's marketing push.
3. Would be **uncontested** among specialty professionals.

A name that is clearly excellent but misses any one of these does NOT get padded
into Tier 1 — it goes to Tier 2 (see cascade rule below). Currently 6 names; the
real-world consensus ceiling is ~10–20.

**Estates** (confidence noted)
- **Hacienda La Esmeralda** — Boquete, Panama. *Very high.* Peterson family; the
  estate that put Panama Geisha on the map (2004); 2025 BoP washed Geisha 98 pts.
- **Lamastus Family Estates (Elida / Luito Geisha)** — Boquete, Panama. *Very
  high.* Repeat Best of Panama champions; record auction prices.
- **Finca El Injerto** — Huehuetenango, Guatemala. *Very high.* Aguirre family,
  est. 1874; one of the most respected estates worldwide, Pacamara & Geisha.
- **Café Granja La Esperanza (CGLE)** — Valle del Cauca, Colombia. *High.*
  Rigoberto Herrera; 5 farms (**Cerro Azul, Las Margaritas**, La Esperanza,
  Potosí, Hawaii). BoP-winning Cerro Azul Geisha; 2012 SCAA "Triple Crown".
- **Gesha Village** — Bench Maji, Ethiopia. *High.* Origin-of-Geisha estate;
  category-defining anchor of the Ethiopia Geisha story.
- **Ninety Plus / Gesha Estates & Barú** — Panama (and Ethiopia). *High, with a
  caveat.* Fermentation pioneers; world-championship lots — but ownership /
  sustainability controversy makes the "uncontested" leg weaker than the rest.

**Deliberately held OUT of Tier 1** (excellent, but miss a leg → Tier 2 top):
Finca Deborah (Panama), Kotowa, Sophia's/Nuguo, Carmen Estate, La Palma y El
Tucán (Colombia), Alo / Daye Bensa (Ethiopia producer marques).

**Region × variety signatures at this tier**: Panama Geisha (Boquete / Volcán,
bajareque mist + volcanic soil), competition-grade Colombian Geisha, top
Ethiopian Geisha/heirloom lots.

## Tier 2 — long-recognized, broadly trusted quality (specialty only)

Sustained reputation for quality — the "you rarely go wrong here" set — without
the singular auction-legend status of Tier 1. Three axes below.

**Scope: specialty only.** Commercial-volume producers/exporters are excluded
*even if they run a premium arm* — a name that also moves commercial coffee is
not a trustworthy bare-name signal (see Alo vs Daye Bensa below). We list only
operations whose identity IS specialty.

### A. Sub-regions (产区) — ADOPTED (allowlist; non-listed = null, not a demerit)

**Inclusion rule (user decision this session):**
1. **Granularity varies by origin** — the unit is the *finest* sub-national name
   that carries a firm, multi-year competition/auction track record. That level
   differs by origin (woreda / department / county / district); it is NOT forced
   to one uniform level.
2. **Basis = competition record, not fame** — the name must recur in Cup of
   Excellence / Best of Panama / a national "Best of" / the Kenyan auction system.
3. **If the only workable granularity is too coarse for its record, EXCLUDE** and
   prefer null. (This is exactly why Peru is left out — see below.)
4. **This is an allowlist.** A coffee that matches nothing here gets `null` on the
   region axis. That is the normal state for most coffee, NOT a demerit — there is
   nothing to "verify" for an unlisted origin; the burden is on *inclusion*.

**Verified this session (Sources):**
- **Ethiopia** — unit: zone → woreda; basis: Ethiopia CoE.
  Gedeo (Yirgacheffe): Yirgacheffe, Kochere, Gedeb · Sidama: **Bensa** · Guji:
  Hambela, Shakiso. *(User candidate Banko Taratu = Gedeb / Gedeo — matches.)*
- **Colombia** — unit: department; basis: CoE + Best of Huila/Cauca/Nariño/Tolima.
  Huila, Nariño, Cauca, Tolima.
- **Kenya** — unit: county; basis: auction + consensus (Kenya runs no CoE).
  Nyeri, Kirinyaga.
- **Panama** — unit: district; basis: Best of Panama.
  Boquete, Volcán, Renacimiento.

**Excluded → null (recorded so the reasoning is auditable):**
- **Peru** (Cusco / Cajamarca / Amazonas / Puno) — only the big *region* granularity
  is available and its competition record is still emerging (expo / World of Coffee
  wins, not a deep CoE track record). Excluded per rule 3. *(User candidates Alina
  Solano, Jhon Saenz → null.)*
- **Embu** (Kenya, emerging), **Yemen** (country-level only, too coarse), Bolivia,
  Ecuador, Rwanda / Burundi — thin or too-coarse, left null.
- **Tanzania (Arusha)**, **Brazil** — no positive competition evidence at an
  appropriate granularity; null (Brazil also off-thesis on altitude — sub-1200 m
  ceiling). *(User candidates Acacia ×4, Valdeir → null; they stand on estate /
  accolade instead.)*

**Pending (add only when CoE-pulled):** Guatemala (Antigua, Huehuetenango) and
Costa Rica (Tarrazú) are consensus-established but were NOT individually verified
this session; held out until their competition records are pulled, per the
conservative "prefer exclude" stance.

### B. Notable specialty estates that miss the Tier 1 bar — 10 (all verified this session)
Excellent and globally known, but fail one Tier 1 leg (single-market halo,
regional scope, or a newer/experimental track record). All 10 web-verified in
this session (Sources); confidence high unless noted.
- **Finca Deborah** (Volcán, Panama) — Jamison Savage; WBC-winning lots.
- **Kotowa** (Boquete, Panama) — Best of Panama regular since 2004.
- **Carmen Estate** (Paso Ancho, Panama) — Franceschi family since 1960; top-10
  BoP for ~20 yrs; 2023 1st Washed Geisha 96.50, auction record $10,005/kg.
- **Finca Hartmann** (Santa Clara / Volcán, Panama) — pioneer family since 1940;
  reputation more by heritage + biodiversity than recent auction dominance.
- **Finca Sophia** (Nueva Suiza, Panama) — BoP Washed Geisha 1st 2017 & 2020;
  US$1,300/lb 2020 record. *(Earlier I wrongly merged this with Nuguo — separate
  farms.)*
- **Finca Nuguo** (Panama) — Gallardo family; US$2,568/lb 2021 record; BoP 2025 3rd.
- **La Palma y El Tucán** (Cundinamarca, Colombia) — processing standard-bearer.
- **Finca El Paraíso / Diego Bermúdez** (Piendamó, Cauca, Colombia) — fermentation
  pioneer; chemical engineer with an on-farm microbiology lab.
- **Granja Paraíso 92 / Wilton Benítez** (Piendamó, Cauca, Colombia) — a *separate*
  producer from El Paraíso above (both in Cauca, both "Paraíso" — do not conflate);
  bioreactor / controlled-fermentation star.
- **Finca Inmaculada / Holguín-Ramos family** (Pichindé, **Valle del Cauca**,
  Colombia) — rare varieties (Geisha, Sudan Rume, Laurina, Eugenioides); the
  Fellows small-holder project. In the user's candidate list. *(Corrected from
  "Cauca" — it is Valle del Cauca.)*

### C. Boutique specialty producer marques (bare name ≈ quality signal) — 1
Only small *curator* operations where the name itself vouches for the lot. This
is deliberately a short list — most famous "producers" are really their own
estate and belong in B. Large exporters with a premium arm are OUT of scope
(e.g. Daye Bensa, Cofinet, Primavera): their bare name spans commercial→
competition, so it cannot guarantee a given lot.
- **Alo Coffee** (Bensa, Sidama, Ethiopia) — *high.* Tamiru Tadesse, founded
  2020; Ethiopia Cup of Excellence 2021 on first submission; competition-grade
  naturals/honeys. The archetype of "name = signal".
- The model captures none of this axis — `roaster_stats` tracks the roaster,
  there is no `producer_stats`.

## Signals to log per candidate (as provenance, not score)

- Estate is Tier 1 → note it plainly; it means the green is objectively elite.
- Estate is Tier 2 / CoE-BoP regular → "long-standing quality reputation".
- Competition placing for the *specific lot* → put it in `accolades` (stronger
  than estate reputation, since it's about this lot, still extrinsic).
- No reputation data → say nothing; absence is not a demerit.

## Sources

- Hacienda La Esmeralda — https://haciendaesmeralda.com/ ,
  https://beannbeancoffee.com/blogs/beansider/hacienda-la-esmeralda-pioneering-panama-s-gesha-and-sweeping-the-2025-awards
- Ninety Plus / Finca El Injerto — https://www.tasteatlas.com/best-rated-coffee-beans-in-the-world ,
  https://momoscoffee.net/blogs/origin/finca-el-injerto-a-150-year-family-story-from-the-guatemalan-highlands
- Café Granja La Esperanza — https://drwakefield.com/news-and-views/cafe-granja-la-esperanza-an-insight-into-this-award-winning-producer/ ,
  https://ptscoffee.com/blogs/meet-our-farmers/rigoberto-herrera-cafe-granja-la-esperanza
- Best of Panama / Cup of Excellence — https://bestofpanama.org/competition ,
  https://cupofexcellence.org/
- Regions/terroir — https://cafebarsel.com/en/blogs/news/las-mejores-regiones-productoras-de-cafe-de-especialidad-en-el-mundo ,
  https://perfectdailygrind.com/2020/11/a-guide-to-specialty-coffee-in-panama/
