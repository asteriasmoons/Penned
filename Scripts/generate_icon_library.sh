#!/bin/bash
# Regenerates Vellix/Resources/VellixAssetIconLibrary.swift from the folder
# structure of Vellix/Assets.xcassets. Each group folder (namespace OFF) -> one
# category; each *.imageset -> one icon. Imagesets left at the catalog root land in
# an "Unsorted" category (forced last). Idempotent: only rewrites the Swift file
# when the output changes. Written for macOS /bin/bash (3.2); LC_ALL=C keeps output
# byte-identical across machines.
#
# This file (VellixAssetIconLibrary) is CUSTOM ASSETS ONLY. SF Symbols live in the
# separate VellixSymbolCatalog and are not touched here.
set -euo pipefail
export LC_ALL=C

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CAT="${1:-$SRCROOT/Vellix/Assets.xcassets}"
OUT="${2:-$SRCROOT/Vellix/Resources/VellixAssetIconLibrary.swift}"
[ -d "$CAT" ] || { echo "error: catalog not found at $CAT" >&2; exit 1; }

# Optional per-category ordering. If Scripts/icon_category_order/<Category>.txt
# exists, its listed ids (one per line, that actually exist) come first in that
# order; any remaining icons in the category follow alphabetically. Categories
# without an override file are fully alphabetical. Lets order-sensitive categories
# (e.g. "Moon Phases") keep an intentional order while the rest stay auto-sorted.
ORDER_DIR="${ORDER_DIR:-$SRCROOT/Scripts/icon_category_order}"

# Existing category order. New category folders not in this list are appended
# alphabetically after these; "Unsorted" (root imagesets) is always forced last.
ORDER=(
  "Wavy"
  "Hearts & Love"
  "Stars & Sparkles"
  "Moon Phases"
  "Astrology & Celestial"
  "Spooky & Halloween"
  "Celebration & Party"
  "Health & Medical"
  "Beauty & Self-care"
  "Animals & Pets"
  "Nature & Weather"
  "Kitchen & Food"
  "Home & Furniture"
  "Tech & Devices"
  "Code & Git"
  "Social & Messaging"
  "Documents & Writing"
  "Calendar & Time"
  "Money & Shopping"
  "Arrows & Controls"
  "Text & Formatting"
  "Objects & Misc"
)

MAP="$(mktemp)"; TMPOUT="$(mktemp)"
trap 'rm -f "$MAP" "$TMPOUT" 2>/dev/null || true' EXIT

# category <TAB> id, one per imageset. Root imagesets -> "Unsorted".
while IFS= read -r iset; do
  parent="$(dirname "$iset")"; base="$(basename "$iset")"; id="${base%.imageset}"
  if [ "$parent" = "$CAT" ]; then c="Unsorted"; else c="$(basename "$parent")"; fi
  printf '%s\t%s\n' "$c" "$id"
done < <(find "$CAT" -type d -name '*.imageset' | sort) > "$MAP"

PRESENT=(); while IFS= read -r l; do PRESENT+=("$l"); done < <(cut -f1 "$MAP" | sort -u)
contains(){ local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

FINAL=()
for c in "${ORDER[@]}"; do contains "$c" "${PRESENT[@]}" && FINAL+=("$c"); done
for c in "${PRESENT[@]}"; do [ "$c" = "Unsorted" ] && continue
  contains "$c" "${ORDER[@]}" || FINAL+=("$c"); done
contains "Unsorted" "${PRESENT[@]}" && FINAL+=("Unsorted")

emit_icon(){ printf '            VellixAssetIcon(name: "%s"),\n' "$1"; }

emit_category(){
  local name="$1"
  local id ovf="$ORDER_DIR/$name.txt"
  local allf listedf
  allf="$(mktemp)"; listedf="$(mktemp)"
  awk -F'\t' -v c="$name" '$1==c{print $2}' "$MAP" | sort > "$allf"
  printf '        VellixAssetIconCategory(name: "%s", icons: [\n' "$name"
  if [ -f "$ovf" ]; then
    # Listed ids that actually exist, in the override's order.
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      if grep -qxF "$id" "$allf"; then emit_icon "$id"; printf '%s\n' "$id" >> "$listedf"; fi
    done < "$ovf"
    # Remaining ids (not listed), alphabetical.
    sort "$listedf" -o "$listedf"
    comm -23 "$allf" "$listedf" | while IFS= read -r id; do [ -z "$id" ] && continue; emit_icon "$id"; done
  else
    while IFS= read -r id; do [ -z "$id" ] && continue; emit_icon "$id"; done < "$allf"
  fi
  printf '        ]),\n'
  rm -f "$allf" "$listedf"
}

{
cat <<'HEADER'
//
//  VellixAssetIconLibrary.swift
//  Vellix
//
//  AUTO-GENERATED — DO NOT EDIT BY HAND.
//  Regenerated at build time by Scripts/generate_icon_library.sh from the folder
//  structure of Vellix/Assets.xcassets. Each group folder (namespace OFF) is one
//  category; each *.imageset is one icon. To add or recategorize an icon, move its
//  imageset into the matching category folder in the asset catalog — no Swift edit.
//  Imagesets left at the catalog root appear in an "Unsorted" category. Icons are
//  sorted alphabetically within each category. SF Symbols are not handled here; they
//  live in the separate VellixSymbolCatalog.
//

import Foundation

struct VellixAssetIcon: Identifiable, Hashable {
    var name: String
    var id: String { name }
    var systemName: String? { name.hasPrefix("sf:") ? String(name.dropFirst(3)) : nil }
    var displayName: String { systemName ?? name }
}

struct VellixAssetIconCategory: Identifiable, Hashable {
    var name: String
    var icons: [VellixAssetIcon]
    var id: String { name }
}

enum VellixAssetIconLibrary {
    /// Every asset in the icon library, grouped into categories.
    /// The icon picker renders one category at a time from this list.
    static let categories: [VellixAssetIconCategory] = [
HEADER
for c in "${FINAL[@]}"; do emit_category "$c"; done
cat <<'FOOTER'
    ]

    /// Flattened list of every icon across all categories.
    static let all: [VellixAssetIcon] = categories.flatMap(\.icons)

    /// Set of every known asset name (used for validation).
    static let names: Set<String> = Set(all.map(\.name))

    /// Matches both libraries offered by the icon picker, including OS availability.
    static func isSupported(_ name: String) -> Bool {
        if names.contains(name) { return true }
        guard let symbol = VellixAssetIcon(name: name).systemName else { return false }
        return VellixSymbolCatalog.byName[symbol]?.isAvailable == true
    }
}
FOOTER
} > "$TMPOUT"

if [ -f "$OUT" ] && cmp -s "$TMPOUT" "$OUT"; then
  echo "icon library already up to date."
else
  cp "$TMPOUT" "$OUT"
  echo "icon library regenerated ($(grep -c 'VellixAssetIcon(name:' "$OUT") icons, ${#FINAL[@]} categories)."
fi
