from html import unescape
from pathlib import Path
import re
from urllib.request import urlopen

DOCS_URL = (
    "https://docs.github.com/api/article/body"
    "?pathname=/en/actions/reference/runners/github-hosted-runners"
)
OUTPUT_PATH = Path(".github/data/github-host-runners.yml")
SECTION_HEADINGS = {
    "public": "### Standard GitHub-hosted runners for public repositories",
    "private": "### Standard GitHub-hosted runners for  private repositories",
}
EXCLUDED_LABELS = {"ubuntu-slim"}


def fetch_body():
    with urlopen(DOCS_URL) as response:
        return response.read().decode("utf-8")


def strip_tags(value):
    text = re.sub(r"<[^>]+>", "", value)
    return unescape(" ".join(text.split()))


def extract_tables(markdown):
    tables = {}
    for scope, heading in SECTION_HEADINGS.items():
        start = markdown.find(heading)
        if start == -1:
            raise SystemExit(f"Unable to find {scope} hosted runner section in GitHub Docs.")
        table_start = markdown.find("<table", start)
        table_end = markdown.find("</table>", table_start)
        if table_start == -1 or table_end == -1:
            raise SystemExit(f"Unable to find {scope} hosted runner table in GitHub Docs.")
        tables[scope] = markdown[table_start : table_end + len("</table>")]
    return tables


def normalize_machine_family(value):
    machine = strip_tags(value).lower()
    if machine == "macos":
        return "macos"
    if machine == "windows":
        return "windows"
    if machine == "linux":
        return "linux"
    raise SystemExit(f"Unsupported machine family: {value}")


def normalize_arch(value):
    arch = strip_tags(value).lower()
    if arch == "intel":
        return "x64"
    if arch in {"x64", "arm64"}:
        return arch
    raise SystemExit(f"Unsupported architecture: {value}")


def is_alias_label(label):
    return label.endswith("-latest")


def parse_label_metadata(label, machine_family):
    if machine_family == "linux" and label.startswith("ubuntu-"):
        suffix = label.removeprefix("ubuntu-")
        if suffix.endswith("-arm"):
            suffix = suffix[:-4]
        return {
            "platform_os": "ubuntu",
            "platform_version": suffix,
        }
    if machine_family == "windows" and label.startswith("windows-"):
        suffix = label.removeprefix("windows-")
        if suffix.endswith("-arm"):
            suffix = suffix[:-4]
        parts = suffix.split("-")
        metadata = {
            "platform_os": "windows",
            "platform_version": parts[0],
        }
        if len(parts) > 1:
            metadata["flavor"] = "-".join(parts[1:])
        return metadata
    if machine_family == "macos" and label.startswith("macos-"):
        suffix = label.removeprefix("macos-")
        if suffix.endswith("-intel"):
            suffix = suffix[:-6]
        parts = suffix.split("-")
        metadata = {
            "platform_os": "macos",
            "platform_version": parts[0],
        }
        if len(parts) > 1:
            metadata["flavor"] = "-".join(parts[1:])
        return metadata
    raise SystemExit(f"Unable to infer platform metadata for label: {label}")


def parse_label_entries(cell_html):
    entries = []
    for match in re.finditer(r"<code>(.*?)</code>([^<]*)", cell_html, re.DOTALL):
        label_html = match.group(1)
        suffix = strip_tags(match.group(2)).strip(" ,")
        label = strip_tags(label_html)
        if label in EXCLUDED_LABELS:
            continue
        entry = {"label": label}
        if suffix:
            entry["note"] = suffix
        link_match = re.search(r'href="([^"]+)"', label_html)
        if link_match:
            entry["source"] = unescape(link_match.group(1))
        entries.append(entry)
    return entries


def parse_table(scope, table_html):
    rows = re.findall(r"<tr>(.*?)</tr>", table_html, re.DOTALL)
    parsed = []
    for row_html in rows[1:]:
        cells = re.findall(r"<td>(.*?)</td>", row_html, re.DOTALL)
        if len(cells) != 6:
            continue
        machine_type, cpu, memory, storage, architecture, label_cell = cells
        machine_family = normalize_machine_family(machine_type)
        arch = normalize_arch(architecture)
        resources = {
            "cpu": strip_tags(cpu),
            "memory": strip_tags(memory),
            "storage": strip_tags(storage),
        }
        for label_entry in parse_label_entries(label_cell):
            parsed.append(
                {
                    "visibility": scope,
                    "machine_family": machine_family,
                    "arch": arch,
                    "resources": resources,
                    **label_entry,
                }
            )
    return parsed


def choose_canonical_label(labels):
    primary = sorted(label for label in labels if not is_alias_label(label))
    if primary:
        return primary[0]
    return sorted(labels)[0]


def build_records(flat_entries):
    alias_groups = {}
    for entry in flat_entries:
        group_key = (
            entry.get("source", ""),
            entry["machine_family"],
            entry["arch"],
        )
        alias_groups.setdefault(group_key, set()).add(entry["label"])

    canonical_by_label = {}
    aliases_by_canonical = {}
    for labels in alias_groups.values():
        canonical = choose_canonical_label(labels)
        aliases = sorted(label for label in labels if label != canonical)
        aliases_by_canonical[canonical] = aliases
        for label in labels:
            canonical_by_label[label] = canonical

    records = {}
    for entry in flat_entries:
        canonical = canonical_by_label[entry["label"]]
        record = records.setdefault(
            canonical,
            {
                "label": canonical,
                "aliases": aliases_by_canonical.get(canonical, []),
                "availability": set(),
                "resources": {},
            },
        )
        record["availability"].add(entry["visibility"])
        record["machine_family"] = entry["machine_family"]
        record["arch"] = entry["arch"]
        record.update(parse_label_metadata(canonical, entry["machine_family"]))
        if "source" in entry:
            record["source"] = entry["source"]
        if "note" in entry and "note" not in record:
            record["note"] = entry["note"]

        existing = record["resources"].get(entry["visibility"])
        if existing is None:
            record["resources"][entry["visibility"]] = dict(entry["resources"])
        elif existing != entry["resources"]:
            raise SystemExit(
                "Conflicting resources while merging visibility records "
                f"for {canonical}: {existing} != {entry['resources']}"
            )

    return sorted(
        records.values(),
        key=lambda item: (
            item["machine_family"],
            item["platform_os"],
            item["platform_version"],
            item.get("flavor", ""),
            item["arch"],
            item["label"],
        ),
    )


def yaml_quote(value):
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def emit_resource_block(lines, indent, key, values):
    lines.append(f"{indent}{key}:")
    lines.append(f"{indent}  cpu: {yaml_quote(values['cpu'])}")
    lines.append(f"{indent}  memory: {yaml_quote(values['memory'])}")
    lines.append(f"{indent}  storage: {yaml_quote(values['storage'])}")


def format_yaml(records):
    lines = [
        f"source: {yaml_quote(DOCS_URL)}",
        "runners:",
    ]
    for record in records:
        lines.append(f"  - label: {yaml_quote(record['label'])}")
        lines.append(f"    machine_family: {yaml_quote(record['machine_family'])}")
        lines.append(f"    platform_os: {yaml_quote(record['platform_os'])}")
        lines.append(f"    platform_version: {yaml_quote(record['platform_version'])}")
        if record.get("flavor"):
            lines.append(f"    flavor: {yaml_quote(record['flavor'])}")
        lines.append(f"    arch: {yaml_quote(record['arch'])}")
        if record.get("aliases"):
            lines.append("    aliases:")
            for alias in record["aliases"]:
                lines.append(f"      - {yaml_quote(alias)}")
        if "source" in record:
            lines.append(f"    source: {yaml_quote(record['source'])}")
        if "note" in record:
            lines.append(f"    note: {yaml_quote(record['note'])}")
        lines.append("    availability:")
        for visibility in sorted(record["availability"]):
            lines.append(f"      - {yaml_quote(visibility)}")
        lines.append("    resources:")
        for visibility in sorted(record["resources"]):
            emit_resource_block(lines, "      ", visibility, record["resources"][visibility])
    return "\n".join(lines) + "\n"


def main():
    markdown = fetch_body()
    tables = extract_tables(markdown)
    flat_entries = parse_table("public", tables["public"]) + parse_table(
        "private", tables["private"]
    )
    records = build_records(flat_entries)
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(format_yaml(records), encoding="utf-8")


if __name__ == "__main__":
    main()
