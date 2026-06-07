#!/usr/bin/env python3

import argparse
import ctypes
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Optional, Union


BOOL = ctypes.c_int
RimeSessionId = ctypes.c_size_t


class RimeTraits(ctypes.Structure):
    _fields_ = [
        ("data_size", ctypes.c_int),
        ("shared_data_dir", ctypes.c_char_p),
        ("user_data_dir", ctypes.c_char_p),
        ("distribution_name", ctypes.c_char_p),
        ("distribution_code_name", ctypes.c_char_p),
        ("distribution_version", ctypes.c_char_p),
        ("app_name", ctypes.c_char_p),
        ("modules", ctypes.POINTER(ctypes.c_char_p)),
        ("min_log_level", ctypes.c_int),
        ("log_dir", ctypes.c_char_p),
        ("prebuilt_data_dir", ctypes.c_char_p),
        ("staging_dir", ctypes.c_char_p),
    ]


class RimeComposition(ctypes.Structure):
    _fields_ = [
        ("length", ctypes.c_int),
        ("cursor_pos", ctypes.c_int),
        ("sel_start", ctypes.c_int),
        ("sel_end", ctypes.c_int),
        ("preedit", ctypes.c_char_p),
    ]


class RimeCandidate(ctypes.Structure):
    _fields_ = [
        ("text", ctypes.c_char_p),
        ("comment", ctypes.c_char_p),
        ("reserved", ctypes.c_void_p),
    ]


class RimeMenu(ctypes.Structure):
    _fields_ = [
        ("page_size", ctypes.c_int),
        ("page_no", ctypes.c_int),
        ("is_last_page", BOOL),
        ("highlighted_candidate_index", ctypes.c_int),
        ("num_candidates", ctypes.c_int),
        ("candidates", ctypes.POINTER(RimeCandidate)),
        ("select_keys", ctypes.c_char_p),
    ]


class RimeCommit(ctypes.Structure):
    _fields_ = [
        ("data_size", ctypes.c_int),
        ("text", ctypes.c_char_p),
    ]


class RimeContext(ctypes.Structure):
    _fields_ = [
        ("data_size", ctypes.c_int),
        ("composition", RimeComposition),
        ("menu", RimeMenu),
        ("commit_text_preview", ctypes.c_char_p),
        ("select_labels", ctypes.POINTER(ctypes.c_char_p)),
    ]


class RimeCandidateListIterator(ctypes.Structure):
    _fields_ = [
        ("ptr", ctypes.c_void_p),
        ("index", ctypes.c_int),
        ("candidate", RimeCandidate),
    ]


class RimeApi(ctypes.Structure):
    _fields_ = [
        ("data_size", ctypes.c_int),
        ("setup", ctypes.c_void_p),
        ("set_notification_handler", ctypes.c_void_p),
        ("initialize", ctypes.c_void_p),
        ("finalize", ctypes.c_void_p),
        ("start_maintenance", ctypes.c_void_p),
        ("is_maintenance_mode", ctypes.c_void_p),
        ("join_maintenance_thread", ctypes.c_void_p),
        ("deployer_initialize", ctypes.c_void_p),
        ("prebuild", ctypes.c_void_p),
        ("deploy", ctypes.c_void_p),
        ("deploy_schema", ctypes.c_void_p),
        ("deploy_config_file", ctypes.c_void_p),
        ("sync_user_data", ctypes.c_void_p),
        ("create_session", ctypes.c_void_p),
        ("find_session", ctypes.c_void_p),
        ("destroy_session", ctypes.c_void_p),
        ("cleanup_stale_sessions", ctypes.c_void_p),
        ("cleanup_all_sessions", ctypes.c_void_p),
        ("process_key", ctypes.c_void_p),
        ("commit_composition", ctypes.c_void_p),
        ("clear_composition", ctypes.c_void_p),
        ("get_commit", ctypes.c_void_p),
        ("free_commit", ctypes.c_void_p),
        ("get_context", ctypes.c_void_p),
        ("free_context", ctypes.c_void_p),
        ("get_status", ctypes.c_void_p),
        ("free_status", ctypes.c_void_p),
        ("set_option", ctypes.c_void_p),
        ("get_option", ctypes.c_void_p),
        ("set_property", ctypes.c_void_p),
        ("get_property", ctypes.c_void_p),
        ("get_schema_list", ctypes.c_void_p),
        ("free_schema_list", ctypes.c_void_p),
        ("get_current_schema", ctypes.c_void_p),
        ("select_schema", ctypes.c_void_p),
        ("schema_open", ctypes.c_void_p),
        ("config_open", ctypes.c_void_p),
        ("config_close", ctypes.c_void_p),
        ("config_get_bool", ctypes.c_void_p),
        ("config_get_int", ctypes.c_void_p),
        ("config_get_double", ctypes.c_void_p),
        ("config_get_string", ctypes.c_void_p),
        ("config_get_cstring", ctypes.c_void_p),
        ("config_update_signature", ctypes.c_void_p),
        ("config_begin_map", ctypes.c_void_p),
        ("config_next", ctypes.c_void_p),
        ("config_end", ctypes.c_void_p),
        ("simulate_key_sequence", ctypes.c_void_p),
        ("register_module", ctypes.c_void_p),
        ("find_module", ctypes.c_void_p),
        ("run_task", ctypes.c_void_p),
        ("get_shared_data_dir", ctypes.c_void_p),
        ("get_user_data_dir", ctypes.c_void_p),
        ("get_sync_dir", ctypes.c_void_p),
        ("get_user_id", ctypes.c_void_p),
        ("get_user_data_sync_dir", ctypes.c_void_p),
        ("config_init", ctypes.c_void_p),
        ("config_load_string", ctypes.c_void_p),
        ("config_set_bool", ctypes.c_void_p),
        ("config_set_int", ctypes.c_void_p),
        ("config_set_double", ctypes.c_void_p),
        ("config_set_string", ctypes.c_void_p),
        ("config_get_item", ctypes.c_void_p),
        ("config_set_item", ctypes.c_void_p),
        ("config_clear", ctypes.c_void_p),
        ("config_create_list", ctypes.c_void_p),
        ("config_create_map", ctypes.c_void_p),
        ("config_list_size", ctypes.c_void_p),
        ("config_begin_list", ctypes.c_void_p),
        ("get_input", ctypes.c_void_p),
        ("get_caret_pos", ctypes.c_void_p),
        ("select_candidate", ctypes.c_void_p),
        ("get_version", ctypes.c_void_p),
        ("set_caret_pos", ctypes.c_void_p),
        ("select_candidate_on_current_page", ctypes.c_void_p),
        ("candidate_list_begin", ctypes.c_void_p),
        ("candidate_list_next", ctypes.c_void_p),
        ("candidate_list_end", ctypes.c_void_p),
        ("user_config_open", ctypes.c_void_p),
        ("candidate_list_from_index", ctypes.c_void_p),
        ("get_prebuilt_data_dir", ctypes.c_void_p),
        ("get_staging_dir", ctypes.c_void_p),
        ("commit_proto", ctypes.c_void_p),
        ("context_proto", ctypes.c_void_p),
        ("status_proto", ctypes.c_void_p),
        ("get_state_label", ctypes.c_void_p),
        ("delete_candidate", ctypes.c_void_p),
        ("delete_candidate_on_current_page", ctypes.c_void_p),
        ("get_state_label_abbreviated", ctypes.c_void_p),
        ("set_input", ctypes.c_void_p),
        ("get_shared_data_dir_s", ctypes.c_void_p),
        ("get_user_data_dir_s", ctypes.c_void_p),
        ("get_prebuilt_data_dir_s", ctypes.c_void_p),
        ("get_staging_dir_s", ctypes.c_void_p),
        ("get_sync_dir_s", ctypes.c_void_p),
        ("highlight_candidate", ctypes.c_void_p),
        ("highlight_candidate_on_current_page", ctypes.c_void_p),
        ("change_page", ctypes.c_void_p),
    ]


def b(value: Union[str, Path]) -> bytes:
    return str(value).encode("utf-8")


def decode(value: Optional[bytes]) -> str:
    return value.decode("utf-8") if value else ""


def require(api: RimeApi, name: str):
    pointer = getattr(api, name)
    if not pointer:
        raise RuntimeError(f"librime API missing function: {name}")
    return pointer


def make_modules(names: Optional[str]):
    if not names:
        return None, None
    values = [name.strip().encode("utf-8") for name in names.split(",") if name.strip()]
    array_type = ctypes.c_char_p * (len(values) + 1)
    array = array_type(*values, None)
    return array, ctypes.cast(array, ctypes.POINTER(ctypes.c_char_p))


def create_traits(shared_dir: Path, user_dir: Path, modules) -> RimeTraits:
    logs_dir = user_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    staging_dir = user_dir / "build"
    staging_dir.mkdir(parents=True, exist_ok=True)

    traits = RimeTraits()
    traits.data_size = ctypes.sizeof(RimeTraits) - ctypes.sizeof(ctypes.c_int)
    traits.shared_data_dir = b(shared_dir)
    traits.user_data_dir = b(user_dir)
    traits.distribution_name = b("Simpanin")
    traits.distribution_code_name = b("simpanin")
    traits.distribution_version = b("1.0")
    traits.app_name = b("rime.simpanin.python")
    traits.modules = modules
    traits.min_log_level = 2
    traits.log_dir = b(logs_dir)
    traits.prebuilt_data_dir = b(shared_dir / "build")
    traits.staging_dir = b(staging_dir)
    return traits


def collect_commit(api: RimeApi, session_id: int) -> str:
    get_commit = ctypes.CFUNCTYPE(BOOL, RimeSessionId, ctypes.POINTER(RimeCommit))(require(api, "get_commit"))
    free_commit = ctypes.CFUNCTYPE(BOOL, ctypes.POINTER(RimeCommit))(require(api, "free_commit"))
    parts: list[str] = []
    while True:
        commit = RimeCommit()
        commit.data_size = ctypes.sizeof(RimeCommit) - ctypes.sizeof(ctypes.c_int)
        if not get_commit(session_id, ctypes.byref(commit)):
            break
        parts.append(decode(commit.text))
        free_commit(ctypes.byref(commit))
    return "".join(parts)


def current_context(api: RimeApi, session_id: int, limit: int):
    get_input = ctypes.CFUNCTYPE(ctypes.c_char_p, RimeSessionId)(require(api, "get_input"))
    get_context = ctypes.CFUNCTYPE(BOOL, RimeSessionId, ctypes.POINTER(RimeContext))(require(api, "get_context"))
    free_context = ctypes.CFUNCTYPE(BOOL, ctypes.POINTER(RimeContext))(require(api, "free_context"))
    list_begin = ctypes.CFUNCTYPE(BOOL, RimeSessionId, ctypes.POINTER(RimeCandidateListIterator))(require(api, "candidate_list_begin"))
    list_next = ctypes.CFUNCTYPE(BOOL, ctypes.POINTER(RimeCandidateListIterator))(require(api, "candidate_list_next"))
    list_end = ctypes.CFUNCTYPE(None, ctypes.POINTER(RimeCandidateListIterator))(require(api, "candidate_list_end"))

    raw_input = decode(get_input(session_id))
    preedit = raw_input
    caret = 0
    selected_segment_end = 0

    context = RimeContext()
    context.data_size = ctypes.sizeof(RimeContext) - ctypes.sizeof(ctypes.c_int)
    if get_context(session_id, ctypes.byref(context)):
        preedit = decode(context.composition.preedit) or raw_input
        caret = context.composition.cursor_pos
        selected_segment_end = context.composition.sel_end
        free_context(ctypes.byref(context))

    candidates = []
    iterator = RimeCandidateListIterator()
    if list_begin(session_id, ctypes.byref(iterator)):
        try:
            while len(candidates) < limit and list_next(ctypes.byref(iterator)):
                candidates.append(
                    {
                        "index": iterator.index,
                        "text": decode(iterator.candidate.text),
                        "comment": decode(iterator.candidate.comment),
                    }
                )
        finally:
            list_end(ctypes.byref(iterator))

    return {
        "input": raw_input,
        "preedit": preedit,
        "caret": caret,
        "selected_segment_end": selected_segment_end,
        "candidates": candidates,
    }


def simulate(args) -> dict:
    shared_dir = Path(args.shared_dir).expanduser().resolve()
    librime_path = Path(args.librime).expanduser().resolve()
    if not shared_dir.is_dir():
        raise RuntimeError(f"shared dir not found: {shared_dir}")
    if not (shared_dir / "build").is_dir():
        raise RuntimeError(f"prebuilt dir not found: {shared_dir / 'build'}")
    if not librime_path.is_file():
        raise RuntimeError(f"librime dylib not found: {librime_path}")

    user_dir = Path(args.user_dir).expanduser().resolve() if args.user_dir else Path(tempfile.mkdtemp(prefix="simpanin-rime-sim-"))
    user_dir.mkdir(parents=True, exist_ok=True)
    modules_array, modules_pointer = make_modules(args.modules)
    traits = create_traits(shared_dir, user_dir, modules_pointer)

    library = ctypes.CDLL(str(librime_path))
    library.rime_get_api.restype = ctypes.POINTER(RimeApi)
    api = library.rime_get_api().contents

    setup = ctypes.CFUNCTYPE(None, ctypes.POINTER(RimeTraits))(require(api, "setup"))
    initialize = ctypes.CFUNCTYPE(None, ctypes.POINTER(RimeTraits))(require(api, "initialize"))
    create_session = ctypes.CFUNCTYPE(RimeSessionId)(require(api, "create_session"))
    destroy_session = ctypes.CFUNCTYPE(BOOL, RimeSessionId)(require(api, "destroy_session"))
    finalize = ctypes.CFUNCTYPE(None)(require(api, "finalize"))
    process_key = ctypes.CFUNCTYPE(BOOL, RimeSessionId, ctypes.c_int, ctypes.c_int)(require(api, "process_key"))
    select_schema = ctypes.CFUNCTYPE(BOOL, RimeSessionId, ctypes.c_char_p)(require(api, "select_schema"))
    set_option = ctypes.CFUNCTYPE(None, RimeSessionId, ctypes.c_char_p, BOOL)(require(api, "set_option"))
    select_candidate = ctypes.CFUNCTYPE(BOOL, RimeSessionId, ctypes.c_size_t)(require(api, "select_candidate"))

    session_id = 0
    try:
        setup(ctypes.byref(traits))
        initialize(ctypes.byref(traits))
        session_id = create_session()
        if not session_id:
            raise RuntimeError("failed to create Rime session")
        if not select_schema(session_id, b(args.schema)):
            raise RuntimeError(f"failed to select schema: {args.schema}")
        set_option(session_id, b("ascii_mode"), 0)

        consumed = []
        for char in args.input:
            if ord(char) > 0x7F:
                raise RuntimeError(f"only ASCII key input is supported: {char!r}")
            consumed.append(bool(process_key(session_id, ord(char), 0)))

        result = {
            "schema": args.schema,
            "shared_dir": str(shared_dir),
            "user_dir": str(user_dir),
            "typed": args.input,
            "consumed": consumed,
            "context": current_context(api, session_id, args.limit),
            "commit": "",
        }

        if args.select is not None:
            if not select_candidate(session_id, args.select):
                raise RuntimeError(f"failed to select candidate index: {args.select}")
            result["commit"] = collect_commit(api, session_id)
            result["context_after_select"] = current_context(api, session_id, args.limit)

        return result
    finally:
        if session_id:
            destroy_session(session_id)
        finalize()
        if not args.keep_user_dir and not args.user_dir:
            shutil.rmtree(user_dir, ignore_errors=True)
        # Keep the module array alive until librime has finalized.
        _ = modules_array


def print_text(result: dict) -> None:
    context = result["context"]
    print(f"schema: {result['schema']}")
    print(f"input: {context['input']}")
    print(f"preedit: {context['preedit']}")
    print(f"user_dir: {result['user_dir']}")
    print()
    print("candidates:")
    for candidate in context["candidates"]:
        comment = f"\t{candidate['comment']}" if candidate["comment"] else ""
        print(f"[{candidate['index']}] {candidate['text']}{comment}")
    if result.get("commit"):
        print()
        print(f"commit: {result['commit']}")


def main() -> int:
    root_dir = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Simulate Rime pinyin input and print candidates.")
    parser.add_argument("input", help="ASCII pinyin keys to type, e.g. nihao")
    parser.add_argument("--schema", default="wanxiang", help="Rime schema id, default: wanxiang")
    parser.add_argument("--limit", type=int, default=10, help="candidate count to print, default: 10")
    parser.add_argument("--select", type=int, help="select candidate index and print committed text")
    parser.add_argument("--shared-dir", default=str(root_dir / "SimpaninKeyboard" / "RimeShared"), help="Rime shared data directory")
    parser.add_argument("--user-dir", help="Rime user data directory; defaults to a temporary directory")
    parser.add_argument("--keep-user-dir", action="store_true", help="keep temporary user dir for debugging")
    parser.add_argument("--librime", default="/opt/homebrew/opt/librime/lib/librime.dylib", help="path to librime.dylib")
    parser.add_argument("--modules", help="comma-separated Rime modules to load, e.g. lua,octagram")
    parser.add_argument("--json", action="store_true", help="print JSON output")
    args = parser.parse_args()

    try:
        result = simulate(args)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print_text(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
