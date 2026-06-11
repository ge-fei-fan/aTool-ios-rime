#!/usr/bin/env python3

import argparse
import ctypes
import importlib.util
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Optional


PREDICTION_PLACEHOLDER = "›"
DEFAULT_SCENARIO = (
    ("tianqi", "天气"),
    ("zhenhao", "真好"),
    ("tianqi", "天气"),
)


def load_simulator_module():
    script_path = Path(__file__).with_name("simulate-rime-input.py")
    spec = importlib.util.spec_from_file_location("simulate_rime_input", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load simulator module: {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sim = load_simulator_module()


def candidate_summary(context: dict) -> list[str]:
    return [candidate["text"] for candidate in context["candidates"]]


def find_candidate(context: dict, expected_text: str) -> Optional[dict]:
    for candidate in context["candidates"]:
        if candidate["text"] == expected_text:
            return candidate
    return None


def type_keys(process_key, session_id: int, keys: str) -> list[bool]:
    consumed: list[bool] = []
    for char in keys:
        if ord(char) > 0x7F:
            raise RuntimeError(f"only ASCII key input is supported: {char!r}")
        consumed.append(bool(process_key(session_id, ord(char), 0)))
    return consumed


def select_expected_candidate(
    api,
    session_id: int,
    select_candidate,
    keys: str,
    expected_text: str,
    limit: int,
) -> dict:
    consumed = type_keys(select_expected_candidate.process_key, session_id, keys)
    before_select = sim.current_context(api, session_id, limit)
    candidate = find_candidate(before_select, expected_text)
    if candidate is None:
        raise AssertionError(
            f"candidate {expected_text!r} not found after typing {keys!r}; "
            f"got {candidate_summary(before_select)}"
        )
    if not select_candidate(session_id, candidate["index"]):
        raise RuntimeError(f"failed to select candidate index: {candidate['index']}")
    commit = sim.collect_commit(api, session_id)
    after_select = sim.current_context(api, session_id, limit)
    if commit != expected_text:
        raise AssertionError(
            f"unexpected commit for {keys!r}; expected {expected_text!r}, got {commit!r}"
        )
    return {
        "typed": keys,
        "expected": expected_text,
        "consumed": consumed,
        "selected_index": candidate["index"],
        "context_before_select": before_select,
        "commit": commit,
        "context_after_select": after_select,
    }


def run_prediction_test(args) -> dict:
    root_dir = Path(__file__).resolve().parents[1]
    shared_dir = Path(args.shared_dir).expanduser().resolve()
    librime_path = Path(args.librime).expanduser().resolve()
    if not shared_dir.is_dir():
        raise RuntimeError(f"shared dir not found: {shared_dir}")
    if not (shared_dir / "build").is_dir():
        raise RuntimeError(f"prebuilt dir not found: {shared_dir / 'build'}")
    if not librime_path.is_file():
        raise RuntimeError(f"librime dylib not found: {librime_path}")

    if args.user_dir:
        user_dir = Path(args.user_dir).expanduser().resolve()
    else:
        user_dir = Path(tempfile.mkdtemp(prefix="simpanin-rime-predict-"))
    user_dir.mkdir(parents=True, exist_ok=True)
    if not args.no_create_lua_parent:
        (user_dir / "lua").mkdir(parents=True, exist_ok=True)

    modules_array, modules_pointer = sim.make_modules(args.modules)
    traits = sim.create_traits(shared_dir, user_dir, modules_pointer)

    library = ctypes.CDLL(str(librime_path))
    library.rime_get_api.restype = ctypes.POINTER(sim.RimeApi)
    api = library.rime_get_api().contents

    setup = ctypes.CFUNCTYPE(None, ctypes.POINTER(sim.RimeTraits))(sim.require(api, "setup"))
    initialize = ctypes.CFUNCTYPE(None, ctypes.POINTER(sim.RimeTraits))(sim.require(api, "initialize"))
    create_session = ctypes.CFUNCTYPE(sim.RimeSessionId)(sim.require(api, "create_session"))
    destroy_session = ctypes.CFUNCTYPE(sim.BOOL, sim.RimeSessionId)(sim.require(api, "destroy_session"))
    finalize = ctypes.CFUNCTYPE(None)(sim.require(api, "finalize"))
    process_key = ctypes.CFUNCTYPE(sim.BOOL, sim.RimeSessionId, ctypes.c_int, ctypes.c_int)(sim.require(api, "process_key"))
    select_schema = ctypes.CFUNCTYPE(sim.BOOL, sim.RimeSessionId, ctypes.c_char_p)(sim.require(api, "select_schema"))
    set_option = ctypes.CFUNCTYPE(None, sim.RimeSessionId, ctypes.c_char_p, sim.BOOL)(sim.require(api, "set_option"))
    get_option = ctypes.CFUNCTYPE(sim.BOOL, sim.RimeSessionId, ctypes.c_char_p)(sim.require(api, "get_option"))
    select_candidate = ctypes.CFUNCTYPE(sim.BOOL, sim.RimeSessionId, ctypes.c_size_t)(sim.require(api, "select_candidate"))

    select_expected_candidate.process_key = process_key

    session_id = 0
    result = {
        "pass": False,
        "schema": args.schema,
        "shared_dir": str(shared_dir),
        "user_dir": str(user_dir),
        "librime": str(librime_path),
        "modules": args.modules or "",
        "created_lua_parent": not args.no_create_lua_parent,
        "steps": [],
    }
    try:
        setup(ctypes.byref(traits))
        initialize(ctypes.byref(traits))
        session_id = create_session()
        if not session_id:
            raise RuntimeError("failed to create Rime session")
        if not select_schema(session_id, sim.b(args.schema)):
            raise RuntimeError(f"failed to select schema: {args.schema}")
        set_option(session_id, sim.b("ascii_mode"), 0)
        set_option(session_id, sim.b("prediction"), 1)
        result["prediction_option"] = bool(get_option(session_id, sim.b("prediction")))

        for keys, expected_text in DEFAULT_SCENARIO:
            step = select_expected_candidate(
                api,
                session_id,
                select_candidate,
                keys,
                expected_text,
                args.limit,
            )
            result["steps"].append(step)

        final_context = result["steps"][-1]["context_after_select"]
        prediction_candidates = final_context["candidates"]
        result["prediction_input"] = final_context["input"]
        result["prediction_candidates"] = prediction_candidates
        result["predict_db_path"] = str(user_dir / "lua" / "predict.userdb")

        if final_context["input"] != PREDICTION_PLACEHOLDER:
            raise AssertionError(
                f"expected prediction placeholder {PREDICTION_PLACEHOLDER!r}, "
                f"got input {final_context['input']!r}"
            )
        if not any(candidate["text"] == "真好" for candidate in prediction_candidates):
            raise AssertionError(
                f"expected prediction candidate '真好', got {candidate_summary(final_context)}"
            )

        result["pass"] = True
        return result
    except Exception as error:
        result["error"] = str(error)
        return result
    finally:
        if session_id:
            destroy_session(session_id)
        finalize()
        if not args.keep_user_dir and not args.user_dir:
            shutil.rmtree(user_dir, ignore_errors=True)
        _ = modules_array
        _ = root_dir


def print_text(result: dict) -> None:
    print(f"pass: {str(result['pass']).lower()}")
    print(f"schema: {result['schema']}")
    print(f"user_dir: {result['user_dir']}")
    print(f"prediction option: {result.get('prediction_option')}")
    print()
    for index, step in enumerate(result["steps"], start=1):
        candidates = candidate_summary(step["context_before_select"])
        print(f"step {index}: typed {step['typed']} -> commit {step['commit']}")
        print(f"  selected index: {step['selected_index']}")
        print(f"  candidates before select: {', '.join(candidates)}")
        print(f"  input after select: {step['context_after_select']['input']}")
    print()
    print(f"prediction input: {result.get('prediction_input', '')}")
    prediction_candidates = [
        candidate["text"] for candidate in result.get("prediction_candidates", [])
    ]
    print(f"prediction candidates: {', '.join(prediction_candidates)}")
    if result.get("error"):
        print()
        print(f"error: {result['error']}")


def main() -> int:
    root_dir = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Train and verify Wanxiang post-predict candidates.")
    parser.add_argument("--schema", default="wanxiang", help="Rime schema id, default: wanxiang")
    parser.add_argument("--limit", type=int, default=20, help="candidate count to inspect, default: 20")
    parser.add_argument("--shared-dir", default=str(root_dir / "SimpaninKeyboard" / "RimeShared"), help="Rime shared data directory")
    parser.add_argument("--user-dir", help="Rime user data directory; defaults to a temporary directory")
    parser.add_argument("--keep-user-dir", action="store_true", help="keep temporary user dir for debugging")
    parser.add_argument("--librime", default="/opt/homebrew/lib/librime.dylib", help="path to librime.dylib")
    parser.add_argument("--modules", help="comma-separated Rime modules to load, e.g. lua,octagram")
    parser.add_argument("--no-create-lua-parent", action="store_true", help="do not pre-create user_dir/lua; useful for reproducing LevelDB parent-dir failures")
    parser.add_argument("--json", action="store_true", help="print JSON output")
    args = parser.parse_args()

    result = run_prediction_test(args)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print_text(result)
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
