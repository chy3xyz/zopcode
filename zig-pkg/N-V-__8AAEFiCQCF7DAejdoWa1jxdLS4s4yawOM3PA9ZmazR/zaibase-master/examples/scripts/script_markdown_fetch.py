import json
import sys


def main() -> int:
    request = json.load(sys.stdin)
    params = json.loads(request["params_json"])
    url = params["url"]

    payload = {
        "source": "script-markdown-fetch",
        "url": url,
        "markdown": f"# Fetched\\n\\nSource: {url}",
    }
    print(json.dumps({"ok": True, "output_json": json.dumps(payload, ensure_ascii=False)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
