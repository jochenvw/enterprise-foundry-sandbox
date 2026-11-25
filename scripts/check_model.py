import json
import sys


def check_model(parameters, catalog):
    name = parameters["centralModelName"]["value"]
    version = parameters["centralModelVersion"]["value"]
    sku = parameters["centralModelSkuName"]["value"]
    models = [
        entry["model"]
        for entry in catalog
        if entry.get("kind") == "AIServices"
        and entry.get("model", {}).get("format") == "OpenAI"
        and entry["model"].get("name") == name
    ]
    matching = [
        model
        for model in models
        if model.get("version") == version
        or (version == "latest" and model.get("isDefaultVersion"))
    ]
    if not matching:
        versions = ", ".join(sorted({model["version"] for model in models}))
        raise ValueError(
            f"Model {name!r} version {version!r} is unavailable. "
            f"Available versions: {versions or 'none'}. "
            "Update centralModelName / centralModelVersion."
        )
    if not any(
        option.get("name") == sku
        for model in matching
        for option in (model.get("skus") or [])
    ):
        raise ValueError(
            f"Model {name!r} version {version!r} does not support SKU {sku!r}. "
            "Update centralModelSkuName."
        )
    return f"Model {name!r} version {version!r} supports SKU {sku!r}."


def main():
    parameters_file, catalog_file, location = sys.argv[1:]
    try:
        with open(parameters_file, encoding="utf-8") as source:
            parameters = json.load(source)["parameters"]
        with open(catalog_file, encoding="utf-8") as source:
            catalog = json.load(source)
        print(f"OK ({location}): {check_model(parameters, catalog)}")
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"ERROR ({location}): {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
