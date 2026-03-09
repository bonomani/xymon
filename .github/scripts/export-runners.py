from datetime import datetime, timezone
from html import unescape
from pathlib import Path
import re
from urllib.request import urlopen

DOCS_URL = (
    "https://docs.github.com/api/article/body"
    "?pathname=/en/actions/reference/runners/github-hosted-runners"
)
OUTPUT_PATH = Path(".github/data/runtime-runners.yml")


def fetch_body():
    with urlopen(DOCS_URL) as response:
        return response.read().decode("utf-8")


def strip_tags(value):
    text = re.sub(r"<[^>]+>", "", value)
    return unescape(" ".join(text.split()))


def extract_tables(markdown):
    headings = {
        "public": "### Standard GitHub-hosted runners for public repositories",
        "private": "### Standard GitHub-hosted runners for  private repositories",
    }
    tables = {}
    for scope, heading in headings.items():
        start = markdown.find(heading)
        if start == -1:
            raise SystemExit(f"Unable to find {scope} hosted runner section in GitHub Docs.")
        table_start = markdown.find("<table", start)
        table_end = markdown.find("</table>", table_start)
        if table_start == -1 or table_end == -1:
            raise SystemExit(f"Unable to find {scope} hosted runner table in GitHub Docs.")
        tables[scope] = markdown[table_start : table_end + len("</table>")]
    return tables


def parse_labels(cell_html):
    entries = []
    for match in re.finditer(r"<code>(.*?)</code>([^<]*)", cell_html, re.DOTALL):
        label_html = match.group(1)
        suffix = strip_tags(match.group(2)).strip(" ,")
        label = strip_tags(label_html)
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
        base = {
            "visibility": scope,
            "machine_type": strip_tags(machine_type),
            "cpu": strip_tags(cpu),
            "memory": strip_tags(memory),
            "storage": strip_tags(storage),
            "architecture": strip_tags(architecture),
        }
        for label in parse_labels(label_cell):
            parsed.append(base | label)
    return parsed


def yaml_quote(value):
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def format_yaml(runners):
    lines = [
        f"generated_at: {datetime.now(timezone.utc).replace(microsecond=0).isoformat()}",
        f"source: {yaml_quote(DOCS_URL)}",
        "runners:",
    ]
    for runner in runners:
        lines.append(f"  - label: {yaml_quote(runner['label'])}")
        lines.append(f"    visibility: {yaml_quote(runner['visibility'])}")
        lines.append(f"    machine_type: {yaml_quote(runner['machine_type'])}")
        lines.append(f"    cpu: {yaml_quote(runner['cpu'])}")
        lines.append(f"    memory: {yaml_quote(runner['memory'])}")
        lines.append(f"    storage: {yaml_quote(runner['storage'])}")
        lines.append(f"    architecture: {yaml_quote(runner['architecture'])}")
        if "source" in runner:
            lines.append(f"    source: {yaml_quote(runner['source'])}")
        if "note" in runner:
            lines.append(f"    note: {yaml_quote(runner['note'])}")
    return "\n".join(lines) + "\n"


def main():
    markdown = fetch_body()
    tables = extract_tables(markdown)
    runners = parse_table("public", tables["public"]) + parse_table("private", tables["private"])
    runners.sort(key=lambda item: (item["label"], item["visibility"]))
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(format_yaml(runners), encoding="utf-8")


if __name__ == "__main__":
    main()
