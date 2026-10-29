"""Regenerate one README screenshot mockup with Gemini (maintainer tooling, not part of the plugin).
Usage: GOOGLE_GENERATIVE_AI_API_KEY=... python3 assets/screens/gen.py assets/screens/prompts/hero.txt /tmp/hero.png
then: magick /tmp/hero.png -resize 1600x -strip -quality 88 assets/screens/hero.webp
Model: GEN_MODEL (default gemini-3-pro-image). Each call is a paid image generation."""
import base64, json, os, sys, urllib.request

prompt_file, out, *refs = sys.argv[1:]
model = os.environ.get("GEN_MODEL", "gemini-3-pro-image")
parts = [{"text": open(prompt_file).read()}]
for r in refs:
    parts.append({"inlineData": {"mimeType": "image/png", "data": base64.b64encode(open(r, "rb").read()).decode()}})
body = {
    "contents": [{"parts": parts}],
    "generationConfig": {
        "responseModalities": ["IMAGE"],
        "imageConfig": {"aspectRatio": os.environ.get("GEN_ASPECT", "16:9"), "imageSize": os.environ.get("GEN_SIZE", "2K")},
    },
}
req = urllib.request.Request(
    f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-goog-api-key": os.environ["GOOGLE_GENERATIVE_AI_API_KEY"]},
)
try:
    j = json.load(urllib.request.urlopen(req, timeout=300))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read()[:500].decode()}")
for p in j.get("candidates", [{}])[0].get("content", {}).get("parts", []):
    if "inlineData" in p:
        open(out, "wb").write(base64.b64decode(p["inlineData"]["data"]))
        print(out, j.get("usageMetadata", {}).get("totalTokenCount"))
        break
else:
    sys.exit("no image: " + json.dumps(j)[:500])
