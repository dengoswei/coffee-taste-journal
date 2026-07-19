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

RATING_SCORES = {
    "Disliked": 0,
    "General": 1,
    "So So": 1,
    "Ok": 2,
    "OK": 2,
    "Liked": 3,
    "Good": 3,
    "Loved": 4,
    "Great": 4,
}

CATEGORY_TERMS: dict[str, tuple[str, ...]] = {
    "fruit.berry": (
        "berry", "berries", "blackberry", "blueberry", "cranberry", "raspberry",
        "strawberry", "redcurrant", "blackcurrant", "elderberry", "莓", "覆盆子",
        "草莓", "蓝莓", "蔓越莓", "黑莓", "红醋栗", "黑醋栗",
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
        "raisin", "dried", "date", "prune", "fruit leather", "果干", "葡萄干",
        "椰枣", "西梅",
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
        "floral", "jasmine", "honeysuckle", "hibiscus", "rose", "lavender",
        "chamomile", "flower", "花香", "茉莉", "金银花", "玫瑰", "薰衣草",
        "洋甘菊",
    ),
    "tea": (
        "tea", "earl grey", "pu'er", "puer", "black tea", "green tea", "红茶",
        "绿茶", "伯爵茶", "普洱", "熟普",
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
        "baking spices", "香料", "草本", "桉树", "八角",
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
    haystack = " | ".join(normalized_text(item) for item in descriptors)
    return sorted(
        category
        for category, terms in CATEGORY_TERMS.items()
        if any(term_matches(haystack, term) for term in terms)
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
    return {
        "roaster": coffee.get("roaster") or "",
        "name": coffee.get("name") or "",
        "origin": coffee.get("origin") or "",
        "farm": coffee.get("farm") or "",
        "variety": coffee.get("variety") or "",
        "process": coffee.get("process") or "",
    }


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
        descriptors = [str(item).strip() for item in coffee.get("flavorNotes", []) if str(item).strip()]
        user_quality_signals = quality_matches([tasting_note]) if substantive else []
        claimed_quality_signals = quality_matches(descriptors)
        details = log.get("details") or {}
        rating_label = log["verdict"]
        observations.append({
            "id": f"app_brew_{log['id'].lower()}",
            "entity_id": app_entity_id(coffee),
            "source": "app_brew_log",
            "source_ref": f"{source_path}#brewLogs/{log['id']}",
            "date": log.get("date"),
            "coffee": coffee_payload(coffee),
            "rating": {
                "label": rating_label,
                "score": RATING_SCORES[rating_label],
                "explicit": True,
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
                "limitations": [] if substantive else [
                    "Rating is explicit, but the tasting note is a placeholder.",
                    "Flavor descriptors come from coffee metadata, not confirmed perception.",
                ],
            },
            "provenance_refs": [f"app:{log['id']}"],
        })

    for coffee in store.get("coffees", []):
        if logs_by_coffee.get(coffee["id"]):
            continue
        descriptors = [str(item).strip() for item in coffee.get("flavorNotes", []) if str(item).strip()]
        observations.append({
            "id": f"app_exposure_{coffee['id'].lower()}",
            "entity_id": app_entity_id(coffee),
            "source": "app_coffee_exposure",
            "source_ref": f"{source_path}#coffees/{coffee['id']}",
            "date": None,
            "coffee": coffee_payload(coffee),
            "rating": {
                "label": None,
                "score": None,
                "explicit": False,
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
                "rating_weight": 0.0,
                "descriptor_weight": 0.2,
                "substantive_first_person_note": False,
                "limitations": ["Exposure only; no brew-level rating."],
            },
            "provenance_refs": [f"app:{coffee['id']}"],
        })

    return observations


def enrich_flomo(raw: dict[str, Any]) -> dict[str, Any]:
    observation = dict(raw)
    observation.setdefault("source", "flomo_curated")
    observation.setdefault("context", {})
    observation.setdefault("user_note", "")
    rating = observation.setdefault("rating", {})
    label = rating.get("label")
    rating.setdefault("score", RATING_SCORES.get(label))
    rating.setdefault("explicit", label is not None)
    descriptors = observation.setdefault("sensory", {}).setdefault("descriptors", [])
    observation["sensory"].setdefault("descriptor_origin", "user_note_or_menu_claim")
    observation["sensory"]["descriptor_categories"] = category_matches(descriptors)
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
        "stats": dataset_stats(observations),
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
