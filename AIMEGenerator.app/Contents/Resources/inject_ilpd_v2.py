#!/usr/bin/env python3
"""
Inject ILPD optical metadata into a QuickTime MOV file.
V2: Uses the Resolve ProRes metadata format (sequential integer key IDs).

Usage:
    python3 inject_ilpd_v2.py input.mov ilpd_data.ilpd output.mov
"""

import struct
import sys
import os
import json
import shutil


def build_atom(atype: bytes, payload: bytes) -> bytes:
    size = 8 + len(payload)
    return struct.pack('>I', size) + atype + payload


def build_full_atom(atype: bytes, version: int, flags: int, payload: bytes) -> bytes:
    vf = struct.pack('>I', (version << 24) | (flags & 0xFFFFFF))
    return build_atom(atype, vf + payload)


def parse_top_level_atoms(path: str):
    fsize = os.path.getsize(path)
    atoms = []
    with open(path, 'rb') as f:
        pos = 0
        while pos < fsize:
            f.seek(pos)
            raw = f.read(16)
            if len(raw) < 8:
                break
            sz = struct.unpack('>I', raw[0:4])[0]
            atype = raw[4:8]
            hdr = 8
            if sz == 1 and len(raw) >= 16:
                sz = struct.unpack('>Q', raw[8:16])[0]
                hdr = 16
            elif sz == 0:
                sz = fsize - pos
            if sz < 8:
                break
            atoms.append((pos, sz, atype, hdr))
            pos += sz
    return atoms


def get_video_duration_and_timescale(moov_data: bytes):
    mvhd_idx = moov_data.find(b'mvhd')
    if mvhd_idx < 4:
        return 600, 600, 1
    atom_start = mvhd_idx - 4
    mvhd = moov_data[atom_start:atom_start + struct.unpack('>I', moov_data[atom_start:atom_start+4])[0]]
    version = mvhd[8]
    if version == 0:
        movie_timescale = struct.unpack('>I', mvhd[20:24])[0]
        movie_duration = struct.unpack('>I', mvhd[24:28])[0]
    else:
        movie_timescale = struct.unpack('>I', mvhd[28:32])[0]
        movie_duration = struct.unpack('>Q', mvhd[32:40])[0]
    return movie_timescale, movie_duration, movie_timescale


def get_next_track_id(moov_data: bytes) -> int:
    mvhd_idx = moov_data.find(b'mvhd')
    if mvhd_idx < 4:
        return 10
    atom_start = mvhd_idx - 4
    version = moov_data[atom_start + 8]
    if version == 0:
        return struct.unpack('>I', moov_data[atom_start + 104:atom_start + 108])[0]
    else:
        return struct.unpack('>I', moov_data[atom_start + 116:atom_start + 120])[0]


def increment_next_track_id(moov_data: bytes) -> bytes:
    mvhd_idx = moov_data.find(b'mvhd')
    if mvhd_idx < 4:
        return moov_data
    atom_start = mvhd_idx - 4
    version = moov_data[atom_start + 8]
    moov_data = bytearray(moov_data)
    offset = atom_start + (104 if version == 0 else 116)
    old_id = struct.unpack('>I', moov_data[offset:offset+4])[0]
    moov_data[offset:offset+4] = struct.pack('>I', old_id + 1)
    return bytes(moov_data)


# Key definitions matching Resolve's ProRes export format.
# Order matters: immersive-media FIRST (key_id=1), then the rest alphabetically.
# Each: (key_name, namespace, dtyp_value)
#   dtyp: 0=implicit/binary, 1=UTF-8, 23=float32, 74=signed_int
METADATA_KEYS = [
    # Key ID 1: immersive-media flag (MUST be first)
    ('com.apple.quicktime.video.presentation.immersive-media', 'mdta', 0),
    # Key ID 2+: optical/camera keys
    ('com.apple.quicktime.proim.camera.camInfo.cameraID', 'mdta', 0),
    ('com.apple.quicktime.proim.optical.lens.calibrationType', 'mdta', 0),
    ('com.apple.quicktime.proim.optical.lens.ilpdFileName', 'mdta', 0),
    ('com.apple.quicktime.proim.optical.lens.ilpdUUID', 'mdta', 0),
    ('com.apple.quicktime.proim.optical.lens.projectionData', 'mdta', 0),
    ('com.apple.quicktime.proim.optical.lens.projectionKind', 'mdta', 0),
]


def build_timed_metadata_sample(ilpd_json: str, ilpd_uuid: str,
                                 ilpd_filename: str, camera_id: str) -> bytes:
    """Build a single timed metadata sample using sequential integer key IDs."""
    items = []

    def make_item(key_id: int, value: bytes) -> bytes:
        size = 8 + len(value)
        return struct.pack('>II', size, key_id) + value

    # Key ID 1: immersive-media — empty/absent is fine (just define it in stsd)
    # We skip it in the sample (matching the reference ProRes behavior)

    # Key ID 2: cameraID
    items.append(make_item(2, camera_id.encode('utf-8')))
    # Key ID 3: calibrationType
    items.append(make_item(3, b'dynamicCalData'))
    # Key ID 4: ilpdFileName
    items.append(make_item(4, ilpd_filename.encode('utf-8')))
    # Key ID 5: ilpdUUID
    items.append(make_item(5, ilpd_uuid.encode('utf-8')))
    # Key ID 6: projectionData (full ILPD JSON)
    items.append(make_item(6, ilpd_json.encode('utf-8')))
    # Key ID 7: projectionKind
    items.append(make_item(7, b'fish'))

    return b''.join(items)


def build_stsd_for_timed_metadata() -> bytes:
    """Build stsd with mebx using sequential integer key IDs."""
    # Build key definitions inside mebx > keys
    key_def_atoms = b''
    for i, (key_name, namespace, dtype_val) in enumerate(METADATA_KEYS):
        key_id = i + 1  # 1-based
        # keyd sub-atom: namespace(4) + key_name
        keyd = build_atom(b'keyd', namespace.encode('ascii') + key_name.encode('utf-8'))
        # dtyp sub-atom: class(4) + type(4)
        dtyp = build_atom(b'dtyp', struct.pack('>II', 0, dtype_val))
        # Wrap in key_id atom (4-byte big-endian integer as the atom type)
        key_id_bytes = struct.pack('>I', key_id)
        key_def_atoms += build_atom(key_id_bytes, keyd + dtyp)

    # keys container
    keys_box = build_atom(b'keys', key_def_atoms)

    # mebx: 6 reserved + 2 data_ref_index + keys
    mebx_header = b'\x00' * 6 + struct.pack('>H', 1)
    mebx = build_atom(b'mebx', mebx_header + keys_box)

    # stsd
    stsd_payload = struct.pack('>I', 1) + mebx
    return build_full_atom(b'stsd', 0, 0, stsd_payload)


def build_timed_metadata_trak(
    track_id: int,
    movie_timescale: int,
    movie_duration: int,
    sample_data_offset: int,
    sample_size: int,
    num_frames: int,
    creation_time: int = 0
) -> bytes:
    """Build trak matching Resolve's ProRes export format.

    Creates num_frames samples, each 1 tick long, all pointing to the same
    data offset (the single sample we wrote into mdat). This makes Resolve
    see valid metadata on every frame.
    """

    # tkhd
    tkhd_payload = (
        struct.pack('>I', creation_time) +
        struct.pack('>I', creation_time) +
        struct.pack('>I', track_id) +
        b'\x00' * 4 +
        struct.pack('>I', movie_duration) +
        b'\x00' * 8 +
        struct.pack('>H', 0) +
        struct.pack('>H', 0) +
        struct.pack('>H', 0) +
        b'\x00' * 2 +
        struct.pack('>9I', 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000) +
        struct.pack('>I', 0) +
        struct.pack('>I', 0)
    )
    tkhd = build_full_atom(b'tkhd', 0, 0xF, tkhd_payload)

    # edts/elst
    elst_payload = (
        struct.pack('>I', 1) +
        struct.pack('>I', movie_duration) +
        struct.pack('>i', 0) +
        struct.pack('>HH', 1, 0)
    )
    elst = build_full_atom(b'elst', 0, 0, elst_payload)
    edts = build_atom(b'edts', elst)

    # Use a metadata timescale that gives 1 tick per frame
    # mdhd duration = num_frames (1 tick per sample)
    meta_timescale = num_frames  # so total duration in seconds = num_frames / num_frames = movie_duration/movie_timescale
    # Actually, we need: meta_duration / meta_timescale == movie_duration / movie_timescale
    # Simplest: meta_timescale = movie_timescale, meta_duration = movie_duration
    # stts: num_frames samples each lasting (movie_duration / num_frames) ticks
    meta_timescale = movie_timescale
    meta_duration = movie_duration
    sample_delta = max(1, movie_duration // num_frames)

    mdhd_payload = (
        struct.pack('>I', creation_time) +
        struct.pack('>I', creation_time) +
        struct.pack('>I', meta_timescale) +
        struct.pack('>I', meta_duration) +
        struct.pack('>HH', 0, 0)
    )
    mdhd = build_full_atom(b'mdhd', 0, 0, mdhd_payload)

    # hdlr
    hdlr_name = b'\x00Timed Metadata Media Handler'
    hdlr_payload = (
        b'\x00' * 4 +
        b'meta' +
        b'appl' +
        b'\x00' * 8 +
        hdlr_name
    )
    hdlr = build_full_atom(b'hdlr', 0, 0, hdlr_payload)

    # minf
    nmhd = build_full_atom(b'nmhd', 0, 0, b'')
    url_entry = build_full_atom(b'url ', 0, 1, b'')
    dref = build_full_atom(b'dref', 0, 0, struct.pack('>I', 1) + url_entry)
    dinf = build_atom(b'dinf', dref)

    # stbl
    stsd = build_stsd_for_timed_metadata()

    # stts: all samples have same duration
    stts_payload = struct.pack('>I', 1) + struct.pack('>II', num_frames, sample_delta)
    stts = build_full_atom(b'stts', 0, 0, stts_payload)

    # stsc: 1 sample per chunk
    stsc_payload = struct.pack('>I', 1) + struct.pack('>III', 1, 1, 1)
    stsc = build_full_atom(b'stsc', 0, 0, stsc_payload)

    # stsz: all samples same size (default_size)
    stsz_payload = struct.pack('>II', sample_size, num_frames)
    stsz = build_full_atom(b'stsz', 0, 0, stsz_payload)

    # co64: all chunks point to the SAME offset (the single sample in mdat)
    co64_payload = struct.pack('>I', num_frames)
    for _ in range(num_frames):
        co64_payload += struct.pack('>Q', sample_data_offset)
    co64 = build_full_atom(b'co64', 0, 0, co64_payload)

    stbl = build_atom(b'stbl', stsd + stts + stsc + stsz + co64)
    minf = build_atom(b'minf', nmhd + dinf + stbl)
    mdia = build_atom(b'mdia', mdhd + hdlr + minf)

    return build_atom(b'trak', tkhd + edts + mdia)


def inject_ilpd(input_path: str, ilpd_path: str, output_path: str):
    with open(ilpd_path, 'r') as f:
        ilpd_json = f.read()
    ilpd_data = json.loads(ilpd_json)
    ilpd_uuid = ilpd_data.get('uuid', '')
    camera_id = ilpd_data.get('cameraID', '')
    ilpd_filename = f"{camera_id}.{ilpd_uuid}.ilpd"

    print(f"ILPD: cameraID={camera_id}, uuid={ilpd_uuid}")

    atoms = parse_top_level_atoms(input_path)
    moov_atom = None
    mdat_atom = None
    for pos, sz, atype, hdr in atoms:
        name = atype.decode('ascii', errors='replace')
        print(f"  {name} at {pos:#x}, size={sz}")
        if atype == b'moov':
            moov_atom = (pos, sz, hdr)
        if atype == b'mdat':
            mdat_atom = (pos, sz, hdr)

    with open(input_path, 'rb') as f:
        f.seek(moov_atom[0])
        moov_data = f.read(moov_atom[1])

    movie_timescale, movie_duration, _ = get_video_duration_and_timescale(moov_data)
    next_track_id = get_next_track_id(moov_data)
    print(f"Movie: timescale={movie_timescale}, duration={movie_duration}, next_track_id={next_track_id}")

    sample_data = build_timed_metadata_sample(ilpd_json, ilpd_uuid, ilpd_filename, camera_id)
    sample_size = len(sample_data)

    # Get frame count from the first video track's stsz
    num_frames = movie_duration  # fallback
    search_idx = 0
    while True:
        trak_idx = moov_data.find(b'trak', search_idx + 1)
        if trak_idx < 4:
            break
        hdlr_idx = moov_data.find(b'hdlr', trak_idx)
        if hdlr_idx > 0 and moov_data[hdlr_idx+12:hdlr_idx+16] == b'vide':
            stsz_idx = moov_data.find(b'stsz', trak_idx)
            if stsz_idx > 0:
                num_frames = struct.unpack('>I', moov_data[stsz_idx+12:stsz_idx+16])[0]
            break
        search_idx = trak_idx

    print(f"Sample size: {sample_size} bytes, video frames: {num_frames}")

    mdat_pos, mdat_sz, mdat_hdr = mdat_atom
    mdat_content_size = mdat_sz - mdat_hdr
    total_mdat_payload = mdat_content_size + sample_size
    need_64bit = (8 + total_mdat_payload) > 0xFFFFFFFF

    wide_before_mdat = any(atype == b'wide' and atoms[i+1][2] == b'mdat'
                          for i, (pos, sz, atype, hdr) in enumerate(atoms)
                          if i + 1 < len(atoms))

    print(f"\nWriting output to: {output_path}")

    with open(input_path, 'rb') as fin, open(output_path, 'wb') as fout:
        buf_size = 64 * 1024 * 1024

        for pos, sz, atype, hdr in atoms:
            if atype == b'mdat':
                break
            if atype == b'wide' and wide_before_mdat and need_64bit:
                continue
            fin.seek(pos)
            fout.write(fin.read(sz))

        if need_64bit:
            extended_size = 16 + total_mdat_payload
            fout.write(struct.pack('>I', 1))
            fout.write(b'mdat')
            fout.write(struct.pack('>Q', extended_size))
        else:
            fout.write(struct.pack('>I', 8 + total_mdat_payload))
            fout.write(b'mdat')

        fin.seek(mdat_pos + mdat_hdr)
        remaining = mdat_content_size
        while remaining > 0:
            chunk = min(buf_size, remaining)
            fout.write(fin.read(chunk))
            remaining -= chunk

        actual_sample_offset = fout.tell()
        fout.write(sample_data)

        new_trak = build_timed_metadata_trak(
            track_id=next_track_id,
            movie_timescale=movie_timescale,
            movie_duration=movie_duration,
            sample_data_offset=actual_sample_offset,
            sample_size=sample_size,
            num_frames=num_frames
        )

        moov_modified = increment_next_track_id(moov_data)
        new_moov = build_atom(b'moov', moov_modified[8:] + new_trak)
        fout.write(new_moov)

    out_size = os.path.getsize(output_path)
    print(f"Done! Output: {out_size} bytes ({out_size/1024/1024:.1f} MB)")
    print(f"Delta: {out_size - os.path.getsize(input_path)} bytes")


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <input.mov> <calibration.ilpd> <output.mov>")
        sys.exit(1)
    inject_ilpd(sys.argv[1], sys.argv[2], sys.argv[3])
