#!/usr/bin/env python3
"""Build a normalized private coffee preference dataset.

The generated dataset separates:
- affective evidence: explicit personal ratings;
- descriptive evidence: flavor families and cup-structure observations;
- extrinsic metadata: roaster, origin, variety, and process;
- context/confounders: brew recipe, rest, repeated brews, and note quality.

Flomo notes are intentionally curated into a small local JSON file. Free-form
memo parsing would create false precision and make duplicate handling opaque.
"""

from __future__ import annotations

import argparse
import json
import re
import unicodedata
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PLACEHOLDER_NOTES = {
    "",
    "fresh cup, note later.",
}

APP_ENTITY_OVERRIDES = {
    "3C3277E2-785D-45C9-975A-64C34594810A": "app_rogue_wave_colombia_geisha",
    "31FFF0FC-1094-4FF6-9245-A46F171D53A2": "app_passenger_neyver_salas",
    "AE9F94BC-CEFF-4635-AC58-B3A50BEBC8D9": "app_black_fox_melao",
    "AC99983A-6160-4880-9B13-F91900769F57": "app_sey_yanacocha_sl9",
    "24429E9F-A4FF-4854-9F15-B0D236472454": "app_bura_keramo_74158",
    "630CF319-3A79-44C2-87CE-A513C5C9AFC6": "app_savage_radiance",
    "9D5513F2-A6BD-4AD0-BFB2-EEDF83A4A971": "app_mirra_san_isidro_bourbon",
    "2100FF62-4357-4E22-B27D-1AF74733770C": "app_highborn_ethiopia_anaerobic",
    "AE07D978-F1ED-479A-AB54-327C2216DCF3": "app_kenya_iria_ini",
    "AFB5D127-D35A-4E00-84F5-6B370133637B": "app_bura_keramo_74158",
    "36646E4E-63DA-45AF-808D-C9618534347F": "app_sumo_sudan_rume",
    "6F470E7A-B779-42E3-81EF-855BBB49D31E": "app_peru_kukipata_sl9",
    "C804CB77-709C-410A-BE06-8D3E025D65E8": "app_colombia_waterfall_gesha",
    "65FFBCC8-B843-4851-AB2E-B7DE3848D97D": "app_ethiopia_toh1",
}

# Brew-log or coffee UUID -> dedupe_key, for app observations that duplicate a
# curated Flomo observation. Without an entry here, cross-source duplicates can
# never collapse because only curated Flomo entries carry dedupe_key.
APP_DEDUPE_OVERRIDES: dict[str, str] = {}

# Canonical like-level scale, worst to best. Two label families feed it: the
# app Verdict enum (Loved/Liked/Ok/Disliked) and curated Flomo labels
# (Great/Good/OK/So So/General). The user confirmed 2026-07-20 that "Ok",
# "So So" and "General" all mean the same thing to them, so the scale is four
# levels rather than five, and every legacy label normalizes onto the English
# app vocabulary. Keeping one vocabulary matters because the tier counts drive
# the top-tier signal — two spellings of the same tier would split it.
RATING_LABELS = ("Disliked", "Ok", "Liked", "Loved")
RATING_SCORE_MIN = 0
RATING_SCORE_MAX = len(RATING_LABELS) - 1
# "Positive" means Liked or better; "negative" means Ok or worse. Import these
# rather than hardcoding 2 / 1 so the scale has a single source of truth.
RATING_POSITIVE_MIN = 2
RATING_NEGATIVE_MAX = 1

RATING_SCORES = {
    "Disliked": 0,
    "Ok": 1,
    "OK": 1,
    "So So": 1,
    "General": 1,
    "Liked": 2,
    "Good": 2,
    "Loved": 3,
    "Great": 3,
}

# Legacy label -> canonical English label.
RATING_CANONICAL_LABELS = {
    label: RATING_LABELS[score] for label, score in RATING_SCORES.items()
}


def canonical_rating_label(label: Any) -> Any:
    """Return the canonical English label, leaving unknown labels untouched."""
    return RATING_CANONICAL_LABELS.get(label, label)


def normalized_rating(value: float) -> float:
    """Map a rating (or weighted average) on the 0-3 scale onto 0-100."""
    span = RATING_SCORE_MAX - RATING_SCORE_MIN
    return max(0.0, min(100.0, ((value - RATING_SCORE_MIN) / span) * 100))

# --- Vocabulary canonicalization -------------------------------------------
# Coffee metadata arrives in two languages and several spellings of the same
# thing. Left alone this fragments the evidence: Gesha/Geisha/瑰夏 split one
# variety across three buckets, "水洗处理 WASHED" never joins "Washed", and
# PERU vs Peru collide inside prior_stat_map (which keys on the normalized
# form, so one row silently overwrites the other). Canonicalizing at ingest
# fixes the counts and, per the user's 2026-07-20 decision, puts everything
# except roaster names into English. The original string is preserved
# alongside as *_source so nothing is lost.

DESCRIPTOR_TRANSLATIONS = {
    "菠萝": "pineapple",
    "橙子": "orange",
    "血橙": "blood orange",
    "柚子": "pomelo",
    "葡萄柚": "grapefruit",
    "黄柠檬": "yellow lemon",
    "黄桃": "yellow peach",
    "枇杷": "loquat",
    "梨": "pear",
    "红布林": "red plum",
    "黑布林": "black plum",
    "黑莓": "blackberry",
    "蔓越莓": "cranberry",
    "深色葡萄": "dark grape",
    "百香果": "passionfruit",
    "芒果": "mango",
    "番石榴": "guava",
    "果酱果干": "jammy dried fruit",
    "蜂蜜甜": "honey sweetness",
    "红茶感": "black tea",
    "熟普": "ripe pu'er",
}

# Bean and farm names with no Latin half anywhere in the source. Kept as an
# explicit table rather than transliterated on the fly, because a wrong guess
# at a producer's name is worse than no translation: these are real people and
# places. Entries marked "transliteration" still need confirming against the
# roaster's own Latin spelling.
NAME_TRANSLATIONS = {
    "莓果乐园": "Berry Paradise",
    # Same coffee the app records as "BURA KERAMO 74158" (both map to
    # entity app_bura_keramo_74158), so this spelling is confirmed.
    "布拉 卡拉莫 74158": "Bura Keramo 74158",
    # Transliteration — the Latin spelling of 卡旺基 is unconfirmed. The farm
    # (Iria-ini FCS, Nyeri, Kenya) is confirmed from the same record.
    "米莉x卡旺基处理站": "Mili x Kawangi Washing Station",
    # Transliteration — Peruvian farm, Latin spelling unconfirmed.
    "赏花庄园": "Shanghua Estate",
}

VARIETY_CANONICAL = {
    "geisha": "Gesha",
    "gesha": "Gesha",
    "gesha 瑰夏": "Gesha",
    "瑰夏": "Gesha",
    "原生种": "Heirloom",
    "原生种 heirloom": "Heirloom",
    "heirloom": "Heirloom",
    "sl9*": "SL9",
}

# Checked in order; first hit wins, so put the specific patterns first.
PROCESS_RULES: tuple[tuple[tuple[str, ...], str], ...] = (
    (("carbonic", "maceration"), "Carbonic Maceration"),
    (("anaerobic washed", "厌氧水洗"), "Anaerobic Washed"),
    (("anaerobic", "厌氧", "anoxic"), "Anaerobic Natural"),
    (("semi-washed", "semi washed", "半水洗"), "Semi-washed"),
    (("honey", "蜜处理"), "Honey"),
    (("washed", "水洗"), "Washed"),
    (("natural", "日晒"), "Natural"),
    (("blend", "拼配"), "Blend"),
)


def translate_descriptor(term: str) -> str:
    """Map a known Chinese flavor term to its English equivalent."""
    stripped = str(term).strip()
    return DESCRIPTOR_TRANSLATIONS.get(stripped, stripped)


def canonical_variety(value: str) -> str:
    stripped = str(value or "").strip()
    if not stripped:
        return ""
    return VARIETY_CANONICAL.get(normalized_text(stripped), stripped)


def canonical_process(value: str) -> str:
    """Bucket a free-form process string into a coarse canonical label.

    Deliberately coarse: the point is to make process_stats countable, not to
    preserve every detail. The full original stays in coffee.process_source.
    """
    stripped = str(value or "").strip()
    if not stripped:
        return ""
    haystack = normalized_text(stripped)
    for needles, canonical in PROCESS_RULES:
        if any(needle in haystack for needle in needles):
            return canonical
    return stripped


def canonical_origin(value: str) -> str:
    stripped = str(value or "").strip()
    if not stripped:
        return ""
    # Multi-origin blends keep their separator but normalize each side.
    if "/" in stripped:
        return " / ".join(
            part.strip().title() for part in stripped.split("/") if part.strip()
        )
    return stripped.title()


def strip_redundant_chinese(value: str) -> str:
    """Drop the Chinese half of a bilingual field when the Latin half stands alone.

    Farm and estate names are routinely written as "食叶蚁台地农场 KUKIPATA
    BELEN" — the Latin part is the name used everywhere else, so keeping both
    just makes identity matching noisier.
    """
    stripped = str(value or "").strip()
    if not stripped:
        return ""
    if stripped in NAME_TRANSLATIONS:
        return NAME_TRANSLATIONS[stripped]
    latin = re.sub(r"[㐀-鿿]+", " ", stripped)
    latin = re.sub(r"\s+", " ", latin).strip(" -–—/|,")
    # Require something substantial, not a stray initial.
    if len(re.sub(r"[^A-Za-z]", "", latin)) >= 3:
        return latin
    return stripped


CATEGORY_TERMS: dict[str, tuple[str, ...]] = {
    "fruit.berry": (
        "berry", "berries", "blackberry", "blueberry", "cranberry", "raspberry",
        "strawberry", "redcurrant", "blackcurrant", "elderberry", "mulberry",
        # Pomegranate is WCR "other fruit"; its tart red-fruit character sits
        # closest to this family. Deliberately English-only: CJK matching is
        # substring-based, so adding 石榴 would also match 番石榴 (guava,
        # already mapped to fruit.tropical).
        "pomegranate",
        "莓", "覆盆子", "草莓", "蓝莓", "蔓越莓", "黑莓", "红醋栗", "黑醋栗", "桑葚",
    ),
    "fruit.citrus": (
        "citrus", "orange", "tangerine", "mandarin", "lemon", "lime", "grapefruit",
        "pomelo", "bergamot", "marmalade", "柑橘", "橙", "橘", "柚", "柠檬",
        "青柠", "佛手柑",
    ),
    "fruit.stone": (
        "peach", "apricot", "nectarine", "plum", "cherry", "loquat", "stone fruit",
        "stonefruit", "桃", "杏", "李", "布林", "樱桃", "枇杷",
    ),
    "fruit.tropical": (
        "mango", "pineapple", "passionfruit", "passion fruit", "guava", "lychee",
        "papaya", "granadilla", "tropical", "芒果", "菠萝", "百香果", "番石榴",
        "荔枝", "木瓜",
    ),
    "fruit.dried": (
        "raisin", "dried", "date", "prune", "fruit leather", "fig", "figs",
        "果干", "葡萄干", "椰枣", "西梅", "无花果",
    ),
    "fruit.grape": (
        "grape", "grapes", "concord", "wine", "葡萄", "葡萄酒", "红酒",
    ),
    "fruit.pome": (
        "apple", "pear", "苹果", "梨",
    ),
    "fruit.melon": (
        "melon", "honeydew", "watermelon", "rock melon", "哈密瓜", "甜瓜", "西瓜",
    ),
    "floral": (
        "floral", "florals", "jasmine", "honeysuckle", "hibiscus", "rose",
        "lavender", "chamomile", "elderflower", "flower", "flowers", "blossom",
        # No bare 花: CJK matching is substring-based and 花 also appears in
        # 无花果 (fig) and 花生 (peanut).
        "花香", "茉莉", "金银花", "接骨木花", "玫瑰", "薰衣草", "洋甘菊", "牡丹",
    ),
    "tea": (
        "tea", "earl grey", "pu'er", "puer", "black tea", "green tea", "oolong",
        "红茶", "绿茶", "伯爵茶", "普洱", "熟普", "乌龙", "白茶",
    ),
    "sweet.browning": (
        "honey", "sugar", "caramel", "molasses", "toffee", "brown sugar", "jam",
        "vanilla", "sweet", "wafer", "candy", "fudge", "蜂蜜", "红糖", "黑糖",
        "焦糖", "果酱", "香草", "甜",
    ),
    "cocoa_nut": (
        "chocolate", "cocoa", "cacao", "nut", "nuts", "almond", "marzipan",
        "praline", "巧克力", "可可", "坚果", "杏仁",
    ),
    "spice_herbal": (
        "spice", "spices", "herbal", "eucalyptus", "anise", "lemon balm",
        "baking spices", "cardamom", "mint", "peppermint", "spearmint",
        "fig leaf", "fig leaves", "香料", "草本", "桉树", "八角", "豆蔻",
        "薄荷", "无花果叶",
    ),
    "fermented_alcoholic": (
        "ferment", "fermented", "anaerobic", "anoxic", "carbonic", "cognac",
        "winey", "wine-like", "alcohol", "发酵", "厌氧", "酒",
    ),
}

QUALITY_TERMS: dict[str, tuple[str, ...]] = {
    "clarity_positive": ("clear", "clarity", "defined", "obvious", "明显", "清晰"),
    "cleanliness_positive": ("clean", "干净", "没有发酵"),
    "acid_sweet_balance_positive": ("acid-sweet", "sweet acidity", "酸甜", "balanced acidity"),
    "brightness_positive": ("bright", "crisp", "refreshing acidity", "明亮"),
    "juiciness_positive": ("juicy", "juice", "多汁"),
    "delicacy_positive": ("delicate", "精致"),
    "complexity_positive": ("complex", "complexity", "复杂"),
    "fermentation_clean_positive": ("no ferment", "没有发酵", "controlled fermentation"),
    "brew_variability": ("not as good", "没有昨天", "worse"),
    "creaminess": ("creamy", "cream", "奶油"),
}


def read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def normalized_text(value: Any) -> str:
    text = unicodedata.normalize("NFKC", str(value or "")).casefold()
    return " ".join(text.split())


def slug(value: str) -> str:
    text = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    text = re.sub(r"[^a-zA-Z0-9]+", "_", text).strip("_").lower()
    return text or "unknown"


def term_matches(haystack: str, term: str) -> bool:
    normalized = normalized_text(term)
    if re.search(r"[a-z0-9]", normalized):
        return re.search(
            rf"(?<![a-z0-9]){re.escape(normalized)}(?![a-z0-9])",
            haystack,
        ) is not None
    return normalized in haystack


def category_matches(descriptors: list[str]) -> list[str]:
    normalized_descriptors = [normalized_text(item) for item in descriptors]
    haystack = " | ".join(normalized_descriptors)
    # "Fig leaf" is an herbal/leaf descriptor, not a dried-fruit claim. Keep
    # other dried-fruit descriptors in the same coffee eligible for the family.
    dried_haystack = " | ".join(
        item
        for item in normalized_descriptors
        if not any(
            term_matches(item, leaf_term)
            for leaf_term in ("fig leaf", "fig leaves", "无花果叶")
        )
    )
    return sorted(
        category
        for category, terms in CATEGORY_TERMS.items()
        if any(
            term_matches(dried_haystack if category == "fruit.dried" else haystack, term)
            for term in terms
        )
    )


def quality_matches(parts: list[str]) -> list[str]:
    haystack = " | ".join(normalized_text(item) for item in parts)
    return sorted(
        signal
        for signal, terms in QUALITY_TERMS.items()
        if any(term_matches(haystack, term) for term in terms)
    )


def app_entity_id(coffee: dict[str, Any]) -> str:
    coffee_id = coffee["id"]
    if coffee_id in APP_ENTITY_OVERRIDES:
        return APP_ENTITY_OVERRIDES[coffee_id]
    key = "_".join(
        slug(str(coffee.get(field, "")))
        for field in ("roaster", "name", "origin", "variety", "process")
    )
    return f"app_{key}"


def coffee_payload(coffee: dict[str, Any]) -> dict[str, Any]:
    """Normalize coffee metadata to the canonical vocabulary.

    Roaster is left verbatim on purpose (user decision 2026-07-20): a roaster's
    name is its identity, and translating 有容乃大 would make it unfindable.
    Everything else is canonicalized so the stats count the same thing once.
    """
    payload = {
        "roaster": (coffee.get("roaster") or "").strip(),
        "name": strip_redundant_chinese(coffee.get("name") or ""),
        "origin": canonical_origin(coffee.get("origin") or ""),
        "farm": strip_redundant_chinese(coffee.get("farm") or ""),
        "variety": canonical_variety(coffee.get("variety") or ""),
        "process": canonical_process(coffee.get("process") or ""),
    }
    # Keep the originals whenever canonicalization actually changed something,
    # so a surprising bucket can always be traced back to the source string.
    for field, original in (
        ("name", coffee.get("name")),
        ("origin", coffee.get("origin")),
        ("farm", coffee.get("farm")),
        ("variety", coffee.get("variety")),
        ("process", coffee.get("process")),
    ):
        original = (original or "").strip()
        if original and original != payload[field]:
            payload[f"{field}_source"] = original
    return payload


def parse_app(store: dict[str, Any], source_path: Path) -> list[dict[str, Any]]:
    coffee_by_id = {coffee["id"]: coffee for coffee in store.get("coffees", [])}
    logs_by_coffee: dict[str, list[dict[str, Any]]] = defaultdict(list)
    observations: list[dict[str, Any]] = []

    for log in store.get("brewLogs", []):
        coffee = coffee_by_id.get(log["coffeeID"])
        if not coffee:
            continue
        logs_by_coffee[coffee["id"]].append(log)
        tasting_note = (log.get("tastingNote") or "").strip()
        substantive = normalized_text(tasting_note) not in PLACEHOLDER_NOTES
        descriptors = [
            translate_descriptor(item)
            for item in coffee.get("flavorNotes", []) if str(item).strip()
        ]
        user_quality_signals = quality_matches([tasting_note]) if substantive else []
        claimed_quality_signals = quality_matches(descriptors)
        details = log.get("details") or {}
        rating_label = canonical_rating_label(log["verdict"])
        rating_score = RATING_SCORES.get(rating_label)
        rating_limitations = (
            [] if rating_score is not None
            else [f"Unmapped verdict label: {rating_label}."]
        )
        observation = {
            "id": f"app_brew_{log['id'].lower()}",
            "entity_id": app_entity_id(coffee),
            "source": "app_brew_log",
            "source_ref": f"{source_path}#brewLogs/{log['id']}",
            "date": log.get("date"),
            "coffee": coffee_payload(coffee),
            "rating": {
                "label": rating_label,
                "score": rating_score,
                "explicit": rating_score is not None,
            },
            "sensory": {
                "descriptors": descriptors,
                "descriptor_origin": "roaster_claim",
                "descriptor_categories": category_matches(descriptors),
                "quality_signals": user_quality_signals,
                "claimed_quality_signals": claimed_quality_signals,
            },
            "user_note": tasting_note,
            "context": {
                "brew_method": details.get("method"),
                "dose_grams": details.get("doseGrams"),
                "water_ratio": details.get("doseWaterRatio"),
                "water_temperature_celsius": details.get("waterTemperatureCelsius"),
                "grind_setting": details.get("grindSetting"),
                "bag_id": log.get("bagID"),
            },
            "evidence": {
                "rating_weight": 1.0 if substantive else 0.72,
                "descriptor_weight": 0.9 if substantive else 0.45,
                "substantive_first_person_note": substantive,
                "limitations": rating_limitations + ([] if substantive else [
                    "Rating is explicit, but the tasting note is a placeholder.",
                    "Flavor descriptors come from coffee metadata, not confirmed perception.",
                ]),
            },
            "provenance_refs": [f"app:{log['id']}"],
        }
        dedupe_key = APP_DEDUPE_OVERRIDES.get(log["id"]) or APP_DEDUPE_OVERRIDES.get(coffee["id"])
        if dedupe_key:
            observation["dedupe_key"] = dedupe_key
        observations.append(observation)

    for coffee in store.get("coffees", []):
        if logs_by_coffee.get(coffee["id"]):
            continue
        descriptors = [
            translate_descriptor(item)
            for item in coffee.get("flavorNotes", []) if str(item).strip()
        ]
        # A bean-level verdict with no brew log is still a real rating the user
        # entered — it just lacks a specific cup behind it. Treat it as an
        # explicit but lower-weight rating rather than discarding it; without
        # this fallback these ratings were silently dropped to weight 0.
        bean_verdict = canonical_rating_label(coffee.get("verdict"))
        bean_score = RATING_SCORES.get(bean_verdict) if bean_verdict else None
        has_bean_rating = bean_score is not None
        observations.append({
            "id": f"app_exposure_{coffee['id'].lower()}",
            "entity_id": app_entity_id(coffee),
            "source": (
                "app_coffee_verdict" if has_bean_rating else "app_coffee_exposure"
            ),
            "source_ref": f"{source_path}#coffees/{coffee['id']}",
            "date": None,
            "coffee": coffee_payload(coffee),
            "rating": {
                "label": bean_verdict if has_bean_rating else None,
                "score": bean_score,
                "explicit": has_bean_rating,
            },
            "sensory": {
                "descriptors": descriptors,
                "descriptor_origin": "roaster_claim",
                "descriptor_categories": category_matches(descriptors),
                "quality_signals": [],
                "claimed_quality_signals": quality_matches(descriptors),
            },
            "user_note": coffee.get("notes") or "",
            "context": {},
            "evidence": {
                "rating_weight": 0.6 if has_bean_rating else 0.0,
                "descriptor_weight": 0.35 if has_bean_rating else 0.2,
                "substantive_first_person_note": False,
                "limitations": (
                    [
                        "Bean-level verdict with no brew log; no specific cup "
                        "or brew parameters behind this rating.",
                        "Flavor descriptors come from coffee metadata, not "
                        "confirmed perception.",
                    ] if has_bean_rating
                    else ["Exposure only; no brew-level rating."]
                ),
            },
            "provenance_refs": [f"app:{coffee['id']}"],
        })

    return observations


def enrich_flomo(raw: dict[str, Any]) -> dict[str, Any]:
    observation = dict(raw)
    observation.setdefault("source", "flomo_curated")
    observation.setdefault("context", {})
    observation.setdefault("user_note", "")
    # Curated entries go through the same canonicalization as app records,
    # otherwise "Fully washed" and "Washed" stay separate buckets.
    observation["coffee"] = coffee_payload(observation.get("coffee") or {})
    rating = observation.setdefault("rating", {})
    label = canonical_rating_label(rating.get("label"))
    if label is not None:
        rating["label"] = label
    rating.setdefault("score", RATING_SCORES.get(label))
    rating.setdefault("explicit", label is not None)
    sensory = observation.setdefault("sensory", {})
    descriptors = [translate_descriptor(item) for item in sensory.setdefault("descriptors", [])]
    sensory["descriptors"] = descriptors
    sensory.setdefault("descriptor_origin", "user_note_or_menu_claim")
    sensory["descriptor_categories"] = category_matches(descriptors)
    evidence = observation.setdefault("evidence", {})
    evidence.setdefault("rating_weight", 0.75 if rating.get("explicit") else 0.0)
    evidence.setdefault("descriptor_weight", 0.55 if descriptors else 0.0)
    evidence.setdefault("substantive_first_person_note", False)
    substantive = bool(evidence["substantive_first_person_note"])
    observation["sensory"]["quality_signals"] = (
        quality_matches([observation.get("user_note", "")])
        if substantive else []
    )
    observation["sensory"]["claimed_quality_signals"] = quality_matches([
        observation.get("user_note", ""),
        *descriptors,
    ])
    evidence.setdefault("limitations", [
        "Flomo entry may mix personal perception with menu or roaster descriptors."
    ])
    observation.setdefault("provenance_refs", [f"flomo:{observation.get('source_ref', observation['id'])}"])
    return observation


def deduplicate(observations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    by_key: dict[str, dict[str, Any]] = {}
    for observation in observations:
        key = observation.pop("dedupe_key", None)
        if not key:
            output.append(observation)
            continue
        if key not in by_key:
            by_key[key] = observation
            output.append(observation)
            continue
        kept = by_key[key]
        kept["provenance_refs"] = sorted(set(
            kept.get("provenance_refs", []) + observation.get("provenance_refs", [])
        ))
        kept["evidence"].setdefault("limitations", []).append(
            f"Collapsed duplicate source entry: {observation['id']}."
        )
    return output


def first_nonempty(values: list[str]) -> str:
    return next((value for value in values if value), "")


def build_entity_summaries(observations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for observation in observations:
        grouped[observation["entity_id"]].append(observation)

    summaries: list[dict[str, Any]] = []
    for entity_id, items in sorted(grouped.items()):
        coffee_fields = {
            field: first_nonempty([str(item["coffee"].get(field) or "") for item in items])
            for field in ("roaster", "name", "origin", "farm", "variety", "process")
        }
        rated = [item for item in items if item["rating"].get("score") is not None]
        weighted_score = sum(
            item["rating"]["score"] * item["evidence"]["rating_weight"]
            for item in rated
        )
        total_weight = sum(item["evidence"]["rating_weight"] for item in rated)
        summaries.append({
            "entity_id": entity_id,
            "coffee": coffee_fields,
            "observation_ids": [item["id"] for item in items],
            "rating_count": len(rated),
            "weighted_rating": round(weighted_score / total_weight, 4) if total_weight else None,
            "rating_labels": [item["rating"]["label"] for item in rated],
            "descriptors": sorted({
                descriptor
                for item in items
                for descriptor in item["sensory"].get("descriptors", [])
            }),
            "descriptor_categories": sorted({
                category
                for item in items
                for category in item["sensory"].get("descriptor_categories", [])
            }),
            "quality_signals": sorted({
                signal
                for item in items
                for signal in item["sensory"].get("quality_signals", [])
            }),
            "claimed_quality_signals": sorted({
                signal
                for item in items
                for signal in item["sensory"].get("claimed_quality_signals", [])
            }),
        })
    return summaries


def dataset_stats(observations: list[dict[str, Any]]) -> dict[str, Any]:
    rated = [item for item in observations if item["rating"].get("score") is not None]
    substantive = [
        item for item in observations
        if item["evidence"].get("substantive_first_person_note")
    ]
    return {
        "observations": len(observations),
        "rated_observations": len(rated),
        "unrated_exposures": len(observations) - len(rated),
        "substantive_first_person_notes": len(substantive),
        "app_observations": sum(item["source"].startswith("app_") for item in observations),
        "flomo_observations": sum(item["source"] == "flomo_curated" for item in observations),
        "rating_distribution": {
            label: sum(item["rating"].get("label") == label for item in rated)
            for label in sorted({item["rating"]["label"] for item in rated})
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--store",
        type=Path,
        default=Path("backups/iphone-20260712-1224-com.dengos.CoffeeJournal/CoffeeJournal/store.json"),
    )
    parser.add_argument(
        "--flomo",
        type=Path,
        default=Path("private/coffee_taste/flomo_observations.json"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("private/coffee_taste/dataset.json"),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    store = read_json(args.store)
    flomo_document = read_json(args.flomo)
    app_observations = parse_app(store, args.store)
    flomo_observations = [enrich_flomo(item) for item in flomo_document["observations"]]
    observations = deduplicate([*app_observations, *flomo_observations])
    collapsed_duplicates = len(app_observations) + len(flomo_observations) - len(observations)
    observations.sort(key=lambda item: (item.get("date") or "", item["id"]))

    dataset = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "privacy": {
            "classification": "private_personal_preference_data",
            "git_policy": "The output path is ignored by git.",
            "raw_flomo_text_included": False,
        },
        "method": {
            "rating_scale": RATING_SCORES,
            "separation": [
                "descriptive sensory evidence",
                "affective preference evidence",
                "extrinsic coffee metadata",
                "brew context and evidence quality",
            ],
            "deduplication": "Curated duplicate keys plus app coffee entity overrides.",
        },
        "source_files": {
            "app_store": str(args.store),
            "flomo_curated": str(args.flomo),
        },
        "stats": {**dataset_stats(observations), "collapsed_duplicates": collapsed_duplicates},
        "observations": observations,
        "entities": build_entity_summaries(observations),
    }
    write_json(args.output, dataset)
    print(json.dumps({
        "output": str(args.output),
        "stats": dataset["stats"],
        "entities": len(dataset["entities"]),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
