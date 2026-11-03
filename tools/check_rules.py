"""Guards for the maintainability rules in AGENTS.md that tools can check.

Fails when App code writes UI text or colors outside their single homes.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "moto_nav_bridge" / "lib"

# Places allowed to hold literal text and colors.
TEXT_HOMES = {"l10n/app_text.dart", "services/guidance/guidance_phrases.dart"}
COLOR_HOME = "ui/navio_theme.dart"
# Language names are written in their own language on purpose.
TEXT_EXCEPTIONS = {("ui/widgets/language_section.dart", "简体中文")}

CJK_STRING = re.compile(r"""(['"])((?:(?!\1).)*[一-鿿](?:(?!\1).)*)\1""")
COLOR = re.compile(r"\bColor\(0x[0-9A-Fa-f]{8}\)")

problems = []
for path in sorted(LIB.rglob("*.dart")):
    rel = path.relative_to(LIB).as_posix()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split("//")[0]
        if rel not in TEXT_HOMES:
            for match in CJK_STRING.finditer(code):
                if (rel, match.group(2)) not in TEXT_EXCEPTIONS:
                    problems.append(f"{rel}:{number}: UI text belongs in l10n/app_text.dart")
        if rel != COLOR_HOME and rel.startswith("ui/") and COLOR.search(code):
            problems.append(f"{rel}:{number}: colors belong in NavioColors (ui/navio_theme.dart)")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("rule guards: UI text and colors are in their homes")
