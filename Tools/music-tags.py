#!/usr/bin/env python3
#
# Tools/music-tags.py
# Ultramix
#
# Makes Music show what is actually in the files.
#
# Music keeps its own database and does not look at a song again once it has
# read it, so a tempo written into the file afterwards - by Ultramix or by
# anything else - stays invisible there. Its scripting dictionary has the
# cure: `refresh`, "update file track information from the current
# information in the track's file".
#
# What this script adds is knowing *which* tracks need it, and what else
# would change if they got it: a refresh takes the file's word for the text
# and the artwork too, so the check first says how many titles, artists and
# albums Music would have to give up. Ratings, play counts, date added and
# playlists live only in Music's database and are not touched.
#
# Everything is asked for in one query per field - thousands of tempos in a
# tenth of a second - rather than a round trip per track, which takes
# minutes over the same library.
#
# Usage:
#   Tools/music-tags.py                 what is out of date (reads only)
#   Tools/music-tags.py --refresh       refresh those tracks
#   Tools/music-tags.py --refresh --all every file track, whatever it says
#

import os
import struct
import subprocess
import sys

SEP = "\x1f"          # rarer than a tab, and no song title holds one
CHUNK = 200           # tracks per refresh call, so progress is visible


# MARK: - Talking to Music

DUMP = f'''
tell application "Music"
	set theIDs to id of every file track of library playlist 1
	set theBPMs to bpm of every file track of library playlist 1
	set theNames to name of every file track of library playlist 1
	set theArtists to artist of every file track of library playlist 1
	set theAlbums to album of every file track of library playlist 1
	set theLocations to location of every file track of library playlist 1
	set out to {{}}
	repeat with i from 1 to (count of theIDs)
		set p to ""
		try
			set p to POSIX path of (item i of theLocations)
		end try
		set end of out to ((item i of theIDs) as text) & "{SEP}" & ((item i of theBPMs) as text) & "{SEP}" & p & "{SEP}" & (item i of theNames) & "{SEP}" & (item i of theArtists) & "{SEP}" & (item i of theAlbums)
	end repeat
	set AppleScript's text item delimiters to linefeed
	return out as text
end tell
'''


def osascript(source):
    result = subprocess.run(["osascript", "-e", source], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"Music did not answer:\n{result.stderr.strip()}")
    return result.stdout


def music_tracks():
    """Every file track Music knows: its id, what it shows, and its file."""
    rows = []
    for line in osascript(DUMP).splitlines():
        parts = line.split(SEP)
        if len(parts) != 6:
            continue
        track_id, bpm, path, name, artist, album = parts
        rows.append({
            "id": int(track_id) if track_id.isdigit() else 0,
            "bpm": int(bpm) if bpm.isdigit() else 0,
            "path": path,
            "name": name, "artist": artist, "album": album,
        })
    return rows


def refresh(ids):
    """Asks Music to read these tracks' files again, in chunks so that a long
    run can be watched and stopped."""
    done = 0
    for start in range(0, len(ids), CHUNK):
        batch = ids[start:start + CHUNK]
        listing = ", ".join(str(i) for i in batch)
        osascript(f'''
tell application "Music"
	repeat with theID in {{{listing}}}
		try
			refresh (track id theID of library playlist 1)
		end try
	end repeat
end tell
''')
        done += len(batch)
        print(f"  refreshed {done} of {len(ids)}", flush=True)


# MARK: - What the files say

def mp4_fields(path):
    """tempo, title, artist and album out of an M4A's own atoms.

    The atoms are walked, not searched for: a four-character name can turn
    up inside somebody else's payload, and a search then reads a number out
    of the wrong field."""
    with open(path, "rb") as handle:
        size = os.path.getsize(path)
        offset = 0
        moov = None
        while offset + 8 <= size:
            handle.seek(offset)
            header = handle.read(8)
            if len(header) < 8:
                break
            length, kind = struct.unpack(">I4s", header)
            if length == 1:
                length = struct.unpack(">Q", handle.read(8))[0]
            elif length == 0:
                length = size - offset
            if length < 8:
                break
            if kind == b"moov":
                handle.seek(offset)
                moov = handle.read(length)
                break
            offset += length
    if moov is None:
        return None, None, None, None

    def children(start, end, skip=0):
        """The atoms directly inside a range: (type, content start, end)."""
        out = []
        at = start + skip
        while at + 8 <= end:
            length, kind = struct.unpack_from(">I4s", moov, at)
            header = 8
            if length == 1:
                length = struct.unpack_from(">Q", moov, at + 8)[0]
                header = 16
            elif length == 0:
                length = end - at
            if length < header or at + length > end:
                break
            out.append((kind, at + header, at + length))
            at += length
        return out

    def descend(start, end, kind, skip=0):
        for name, content, stop in children(start, end, skip):
            if name == kind:
                return content, stop
        return None, None

    udta = descend(8, len(moov), b"udta")
    meta = descend(*udta, b"meta") if udta[0] else (None, None)
    # `meta` is a full atom: four version-and-flags bytes before its children.
    ilst = (None, None)
    if meta[0]:
        for name, content, stop in children(meta[0], meta[1], skip=4):
            if name == b"ilst":
                ilst = (content, stop)
                break
    if not ilst[0]:
        return None, None, None, None

    values = {}
    for name, content, stop in children(*ilst):
        data, data_end = descend(content, stop, b"data")
        if data:
            values[name] = moov[data + 8:data_end]   # version/flags, locale, payload

    tempo = values.get(b"tmpo")
    bpm = int.from_bytes(tempo, "big") if tempo and 0 < len(tempo) <= 4 else None

    def text(name):
        raw = values.get(name)
        return raw.decode("utf-8", "replace") if raw else None

    return bpm, text(b"\xa9nam"), text(b"\xa9ART"), text(b"\xa9alb")


def id3_fields(path):
    """The same out of an MP3's ID3v2 tag."""
    with open(path, "rb") as handle:
        head = handle.read(10)
        if head[:3] != b"ID3":
            return None, None, None, None
        version = head[3]
        if version not in (3, 4) or head[5] & 0xF0:
            return None, None, None, None
        size = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9]
        tag = handle.read(size)

    fields = {}
    offset = 0
    while offset + 10 <= len(tag) and tag[offset] != 0:
        name = tag[offset:offset + 4].decode("latin1", "replace")
        if version == 4:
            length = ((tag[offset + 4] << 21) | (tag[offset + 5] << 14)
                      | (tag[offset + 6] << 7) | tag[offset + 7])
        else:
            length = struct.unpack(">I", tag[offset + 4:offset + 8])[0]
        fields[name] = tag[offset + 10:offset + 10 + length]
        offset += 10 + length

    def text(name):
        raw = fields.get(name)
        if not raw:
            return None
        encoding, body = raw[0], raw[1:]
        if encoding == 0:
            return body.decode("latin1", "replace").strip("\x00").strip()
        if encoding == 1:
            return body.decode("utf-16", "replace").strip("\x00").strip()
        if encoding == 2:
            return body.decode("utf-16-be", "replace").strip("\x00").strip()
        return body.decode("utf-8", "replace").strip("\x00").strip()

    bpm = text("TBPM")
    return bpm, text("TIT2"), text("TPE1"), text("TALB")


def file_fields(path):
    if path.lower().endswith((".m4a", ".m4b", ".mp4")):
        bpm, title, artist, album = mp4_fields(path)
        return (float(bpm) if bpm else None), title, artist, album
    if path.lower().endswith(".mp3"):
        bpm, title, artist, album = id3_fields(path)
        try:
            value = float(bpm) if bpm else None
        except ValueError:
            value = None
        return value, title, artist, album
    return None, None, None, None


# MARK: - The comparison

def check(rows, quiet=False):
    """What Music shows against what the files say. Returns the ids that are
    out of date."""
    agree = missing_in_music = different = no_tempo = gone = 0
    stale = []
    text_changes = {"title": 0, "artist": 0, "album": 0}
    examples = []
    for row in rows:
        path = row["path"]
        if not path or not os.path.exists(path):
            gone += 1
            continue
        try:
            bpm, title, artist, album = file_fields(path)
        except Exception:
            gone += 1
            continue
        # A refresh takes the file's text as well: worth knowing beforehand.
        if title and title != row["name"]:
            text_changes["title"] += 1
        if artist and artist != row["artist"]:
            text_changes["artist"] += 1
        if album and album != row["album"]:
            text_changes["album"] += 1

        if not bpm:
            no_tempo += 1
            continue
        shown = row["bpm"]
        if shown == 0:
            missing_in_music += 1
            stale.append(row["id"])
        elif shown in (round(bpm), int(bpm)):
            agree += 1
        else:
            different += 1
            stale.append(row["id"])
            if len(examples) < 8:
                examples.append((shown, bpm, os.path.basename(path)[:44]))

    if not quiet:
        print(f"{len(rows)} file tracks in Music")
        print(f"  {agree} already show what the file says")
        print(f"  {missing_in_music} show nothing while the file has a tempo")
        print(f"  {different} show a different number")
        print(f"  {no_tempo} files have no tempo of their own")
        if gone:
            print(f"  {gone} files could not be read")
        for shown, bpm, name in examples:
            print(f"      Music {shown:>4}   file {bpm:>7}   {name}")
        print()
        print("A refresh would also take the file's text, which differs on:")
        print(f"  {text_changes['title']} titles, {text_changes['artist']} artists, "
              f"{text_changes['album']} albums")
    return stale


def main():
    arguments = sys.argv[1:]
    do_refresh = "--refresh" in arguments
    everything = "--all" in arguments

    rows = music_tracks()
    if not rows:
        sys.exit("Music has no file tracks - is the library open?")
    stale = check(rows)

    if not do_refresh:
        print()
        print(f"{len(stale)} tracks are out of date. "
              f"Run with --refresh to have Music read those files again.")
        return

    ids = [row["id"] for row in rows] if everything else stale
    if not ids:
        print("\nNothing to refresh.")
        return
    print(f"\nRefreshing {len(ids)} tracks…")
    refresh(ids)

    print("\nAfterwards:")
    check(music_tracks(), quiet=False)


if __name__ == "__main__":
    main()
