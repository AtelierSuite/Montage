"""Writes the sample projects the App Store screenshots open.

Usage: python3 samples.py <iPhone|iPad|Mac> <en|ja>

Prints the directory it wrote the projects to.

Each project is a `.montage` package (see MontageFormats/Package): its
`project.json`, with the media it uses copied into `Media/`. The media is
only ever the sample clips in ~/Developer/ClaudeDocs/Samples, read with
ffprobe (brew install ffmpeg) for the metadata the app would read on import.
Every device gets the same projects, named in the language asked for.
"""
import json, os, shutil, subprocess, sys, tempfile, uuid
from fractions import Fraction

# Device and language are picked from fixed lists rather than taken as given,
# and the projects go into a fresh private directory of the script's own
# making, whose path it prints for capture.sh to copy from and remove.
def choose(value, options):
    for option in options:
        if option == value:
            return option
    sys.exit(__doc__)


if len(sys.argv) != 3:
    sys.exit(__doc__)
DEVICE = choose(sys.argv[1], ("iPhone", "iPad", "Mac"))
LANG = choose(sys.argv[2], ("en", "ja"))
SAMPLES = os.path.expanduser("~/Developer/ClaudeDocs/Samples")
if not os.path.isdir(SAMPLES):
    sys.exit(f"no sample media at {SAMPLES}")
OUT = tempfile.mkdtemp(prefix=f"montage-samples-{DEVICE}-{LANG}-")
JA = LANG == "ja"
# Fixed, so a project's ids are the same on every run.
NAMESPACE = uuid.UUID("6d6f6e74-6167-6500-0000-000000000031")
TIMESCALE = 600


def t(en, ja):
    return ja if JA else en


def ident(*parts):
    return str(uuid.uuid5(NAMESPACE, "/".join(parts))).upper()


# MARK: - Times

def time(seconds):
    """A time as project.json writes it: an exact "value/timescale"."""
    return f"{round(Fraction(seconds) * TIMESCALE)}/{TIMESCALE}"


def time_range(start, duration):
    return {"start": time(start), "duration": time(duration)}


def animatable(value, keyframes=()):
    """A parameter, keyframed if given (seconds from the clip's start, value)."""
    result = {"value": value}
    if keyframes:
        result["keyframes"] = [{"time": time(at), "value": v, "interpolation": "easeInOut"}
                               for at, v in keyframes]
    return result


# MARK: - Media

# The frame rates MediaProbe snaps a file's rate to.
STANDARD_RATES = [24000 / 1001, 24, 25, 30000 / 1001, 30, 48, 50, 60000 / 1001, 60, 100,
                  120000 / 1001, 120, 240]


def rate(text):
    numerator, _, denominator = text.partition("/")
    return float(numerator) / float(denominator or 1) if float(denominator or 1) else 0


def probe(file_name):
    """The media item's metadata, as MediaProbe reads it on import."""
    path = os.path.join(SAMPLES, file_name)
    output = subprocess.run(
        ["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path],
        check=True, capture_output=True, text=True).stdout
    info = json.loads(output)
    streams = info["streams"]
    video = next((s for s in streams if s["codec_type"] == "video"), None)
    audio = next((s for s in streams if s["codec_type"] == "audio"), None)
    # The video's own length where there is video: the container's runs to the
    # end of the longest stream, which in an MP4 is often the audio, a few
    # milliseconds past where AVFoundation ends the file.
    duration = video["duration"] if video and "duration" in video else info["format"]["duration"]
    metadata = {
        "duration": time(Fraction(duration).limit_denominator(TIMESCALE)),
        "naturalSize": [0, 0], "rotation": 0, "nominalFrameRate": 0, "isVariableFrameRate": False,
        "audioChannelCount": 0, "audioSampleRate": 0,
    }
    if video:
        metadata["naturalSize"] = [video["width"], video["height"]]
        turn = next((int(d.get("rotation", 0)) for d in video.get("side_data_list", [])
                     if "rotation" in d), 0)
        # ffprobe reports the turn anticlockwise; the model keeps it clockwise.
        metadata["rotation"] = (-turn) % 360
        nominal, average = rate(video["r_frame_rate"]), rate(video["avg_frame_rate"])
        variable = nominal > 0 and abs(nominal - average) / nominal > 0.01
        nearest = min(STANDARD_RATES, key=lambda r: abs(r - average))
        metadata["isVariableFrameRate"] = variable
        metadata["nominalFrameRate"] = average if variable or abs(nearest - average) / nearest >= 0.002 \
            else nearest
    if audio:
        metadata["audioChannelCount"] = int(audio["channels"])
        metadata["audioSampleRate"] = float(audio["sample_rate"])
    return metadata


class Package:
    """One project being put together, and the media it copies in."""

    def __init__(self, name, render_size=(1920, 1080)):
        self.name = name
        self.media = []
        self.tracks = []
        self.files = []
        self.settings = {"renderSize": list(render_size), "frameDuration": "1/30"}

    def add_media(self, file_name, en, ja):
        """Imports a sample file under a name for the library, and returns its id."""
        item_id = ident(self.name, file_name)
        self.media.append({
            "id": item_id, "name": t(en, ja), "kind": "video",
            "location": {"package": f"Media/{file_name}"}, "metadata": probe(file_name),
        })
        self.files.append(file_name)
        return item_id

    def track(self, kind, clips):
        """Adds a track, its clips laid end to end from `start` where they give one."""
        index = len(self.tracks)
        laid = []
        cursor = 0
        for number, clip in enumerate(clips):
            start = clip.pop("start", cursor)
            clip_id = ident(self.name, str(index), str(number))
            laid.append(clip_body(clip_id, start, **clip))
            cursor = start + clip["duration"]
        self.tracks.append({"id": ident(self.name, "track", str(index)), "kind": kind,
                            "clips": laid, "isMuted": False, "isHidden": False})

    def write(self):
        package = os.path.join(OUT, f"{self.name}.montage")
        os.makedirs(os.path.join(package, "Media"))
        os.makedirs(os.path.join(package, "Cache"))
        for file_name in dict.fromkeys(self.files):
            source, destination = os.path.join(SAMPLES, file_name), os.path.join(package, "Media", file_name)
            # A clone where the file system can make one, so it costs no space.
            if subprocess.run(["cp", "-c", source, destination], capture_output=True).returncode:
                shutil.copyfile(source, destination)
        project = {"formatVersion": 1, "settings": self.settings, "media": self.media, "tracks": self.tracks}
        with open(os.path.join(package, "project.json"), "w", encoding="utf-8") as f:
            json.dump(project, f, indent=2, sort_keys=True, ensure_ascii=False)


def clip_body(clip_id, start, media, source, duration, opacity=None, volume=None,
              position=None, scale=None, effects=(), detached=False):
    transform = {
        "position": position or animatable([0.5, 0.5]),
        "scale": scale or animatable(1.0),
        "rotation": animatable(0.0),
    }
    return {
        "id": clip_id, "mediaID": media, "sourceRange": time_range(source, duration),
        "timelineStart": time(start), "volume": volume or animatable(1.0),
        "opacity": opacity or animatable(1.0), "transform": transform,
        "isAudioDetached": detached, "effects": list(effects),
    }


def color(name, exposure=0.0, contrast=1.0, saturation=1.0, temperature=6500.0):
    return {"id": ident("effect", name), "isEnabled": True, "kind": {"type": "colorCorrection", "parameters": {
        "exposure": animatable(exposure), "contrast": animatable(contrast),
        "saturation": animatable(saturation), "temperature": animatable(temperature),
        "tint": animatable(0.0)}}}


def gain(name, decibels):
    return {"id": ident("effect", name), "isEnabled": True,
            "kind": {"type": "gain", "parameters": {"decibels": animatable(decibels)}}}


def reverb(name):
    return {"id": ident("effect", name), "isEnabled": True,
            "kind": {"type": "reverb", "parameters": {"room": "largeHall", "mix": animatable(0.2)}}}


def mosaic(name, center, size, scale=0.008):
    """A pixelated patch, limited to a rectangle with a slightly soft edge."""
    return {"id": ident("effect", name), "isEnabled": True,
            "kind": {"type": "mosaic", "parameters": {
                "style": "pixelate", "scale": animatable(scale), "strength": animatable(1.0)}},
            "mask": {"shape": "rectangle", "center": animatable(list(center)), "size": animatable(list(size)),
                     "rotation": animatable(0.0), "feather": animatable(0.003), "isInverted": False}}


# MARK: - Projects

def aquarium():
    """Orcas and dolphins: a cut of the tank, a picture-in-picture inset that
    fades and grows in on keyframes, and the music of the place underneath."""
    p = Package(t("Aquarium Day", "水族館の一日"))
    orcas = p.add_media("IMG_3311.mp4", "Orcas", "シャチ")
    turn = p.add_media("IMG_3312.mp4", "Turning Dolphin", "ターンするイルカ")
    glass = p.add_media("IMG_3313.mp4", "At the Glass", "ガラス越しに")
    pair = p.add_media("IMG_3314.MOV", "Dolphin Pair", "イルカのペア")

    p.track("video", [
        dict(media=orcas, source=0.5, duration=9.5, effects=[color("orcas", exposure=0.2, saturation=1.2)]),
        dict(media=pair, source=2, duration=11, effects=[color("pair", contrast=1.1, temperature=6100)]),
        dict(media=turn, source=1, duration=7),
        dict(media=glass, source=0.5, duration=7, effects=[color("glass", saturation=1.15)]),
    ])
    # The inset: half the frame's height, to the right, fading and growing
    # in over its first second, and out over its last.
    p.track("video", [dict(
        start=1.5, media=glass, source=0, duration=7, detached=True,
        opacity=animatable(1.0, [(0, 0.0), (1, 1.0), (6, 1.0), (7, 0.0)]),
        scale=animatable(0.55, [(0, 0.35), (1, 0.55)]),
        position=animatable([0.8, 0.4]),
    )])
    p.track("audio", [
        dict(media=pair, source=0, duration=15, effects=[gain("pair-gain", -6), reverb("pair-reverb")],
             volume=animatable(1.0, [(0, 0.0), (2, 1.0)])),
        dict(media=orcas, source=0, duration=11, effects=[gain("orcas-gain", -3)]),
    ])
    p.write()


def farm():
    """A wet morning on a goat farm: three clips with a warmer grade, the
    first with its sound split off onto a track of its own and a goat inset
    over it. All of that lies in the first ten seconds, which is as much as
    the iPad's timeline shows."""
    p = Package(t("Farm Visit", "牧場さんぽ"))
    shed = p.add_media("IMG_1805.MOV", "Goat Shed", "ヤギ小屋")
    barn = p.add_media("IMG_1813.MOV", "Barn", "納屋")
    yard = p.add_media("IMG_1841.MOV", "Farmyard", "牧場の庭")

    warm = dict(temperature=5600, saturation=1.1)
    p.track("video", [
        dict(media=barn, source=3, duration=10, detached=True, effects=[color("barn", contrast=1.08, **warm)]),
        dict(media=yard, source=4, duration=12, effects=[color("yard", **warm)]),
        dict(media=shed, source=2, duration=8, effects=[color("shed", exposure=0.15, **warm)]),
    ])
    p.track("video", [dict(
        start=4, media=shed, source=11, duration=5, detached=True,
        opacity=animatable(0.9), scale=animatable(0.3), position=animatable([0.2, 0.25]),
    )])
    p.track("audio", [
        dict(media=barn, source=3, duration=10, effects=[gain("barn-gain", 3)],
             volume=animatable(1.0, [(8, 1.0), (10, 0.0)])),
    ])
    p.write()


def reel():
    """A portrait cut for sharing, to show projects of any shape."""
    p = Package(t("Dolphin Reel", "イルカのリール"), render_size=(1080, 1920))
    turn = p.add_media("IMG_3312.mp4", "Turning Dolphin", "ターンするイルカ")
    glass = p.add_media("IMG_3313.mp4", "At the Glass", "ガラス越しに")
    pair = p.add_media("IMG_3314.MOV", "Dolphin Pair", "イルカのペア")
    p.track("video", [
        dict(media=turn, source=0, duration=6),
        dict(media=glass, source=1, duration=5),
        dict(media=pair, source=4, duration=8, effects=[color("reel", saturation=1.2)]),
    ])
    p.track("audio", [dict(media=pair, source=0, duration=15, volume=animatable(0.8),
                           effects=[reverb("reel-reverb")])])
    p.write()


def barn():
    """The barn up close, the gas cylinders' supplier label pixelated: the
    mosaic covers a rectangle around it, as one would a name or a number plate.
    The camera barely moves, so the mask needs no keyframes."""
    p = Package(t("Barn Close-Up", "納屋のアップ"))
    barn = p.add_media("IMG_1813.MOV", "Barn", "納屋")
    yard = p.add_media("IMG_1841.MOV", "Farmyard", "牧場の庭")

    warm = dict(temperature=5600, saturation=1.1)
    p.track("video", [
        # Grown to frame the horse and the cylinders.
        dict(media=barn, source=3, duration=10, scale=animatable(1.6), position=animatable([0.34, 0.42]),
             effects=[mosaic("barn-label", center=(0.668, 0.655), size=(0.12, 0.16))]),
        dict(media=yard, source=4, duration=8, effects=[color("yard-close", **warm)]),
    ])
    p.write()


aquarium()
farm()
reel()
barn()
print(OUT)
