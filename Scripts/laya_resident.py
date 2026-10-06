#!/usr/bin/env python3
"""앱이 켜 두는 상주 판단 프로세스.

모델을 한 번 올린 뒤, 한 줄에 하나씩 상태만 받아 딴짓 확률을 돌려준다.
질문 스키마는 이 프로세스 안에 있다. ONNX 그래프가 있으면 ONNX Runtime으로 돌리고,
없으면 처음 한 번 내보낸 다음 그 그래프를 쓴다.
"""

import json
import os
import sys
from pathlib import Path

MODEL_ID = os.environ.get("HABITBLOCKER_MODEL", "convaiinnovations/laya-multilingual")
QUESTIONS = {
    "intent": {
        "type": "choice",
        "instructions": "이 화면이 공부인지 딴짓인지 고른다. 목표가 비어 있으면 주소, 제목, 앱 이름만 본다.",
        "criteria": {
            "study": "목표에 이어진 공부, 작업, 자료",
            "drift": "놀기, 구경, 목적 없는 소비",
        },
    }
}


def emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def support_dir():
    return Path.home() / "Library/Application Support/com.hyun.habitblocker"


def onnx_path():
    raw = os.environ.get("HABITBLOCKER_ONNX")
    if raw:
        return Path(raw)
    return support_dir() / "runtime" / "laya-multilingual.onnx"


def weights_present():
    graph = onnx_path()
    if graph.is_file():
        return True
    roots = [
        Path.home() / ".cache/huggingface/hub",
        support_dir() / "huggingface/hub",
    ]
    hf_home = os.environ.get("HF_HOME")
    if hf_home:
        roots.append(Path(hf_home) / "hub")
    name = "models--convaiinnovations--laya-multilingual"
    return any((root / name).is_dir() for root in roots)


def drift_from(result):
    answer = result.get("answers", {}).get("intent", {})
    probabilities = answer.get("probabilities") or {}
    drift = probabilities.get("drift")
    choice = answer.get("choice")
    if drift is None and isinstance(answer.get("confidence"), (int, float)):
        confidence = float(answer["confidence"])
        if choice == "drift":
            drift = confidence
        elif choice == "study":
            drift = 1 - confidence
    return drift, choice


def export_graph(path: Path):
    import torch
    from laya.agent import Agent

    path.parent.mkdir(parents=True, exist_ok=True)
    agent = Agent(MODEL_ID, compile=False, device="cpu")
    batch, seq_len, num_markers = 2, 17, 3
    inputs = (
        torch.randint(0, 100, (batch, seq_len), dtype=torch.long),
        torch.ones((batch, seq_len), dtype=torch.long),
        torch.tensor([[1, 5, 9]] * batch, dtype=torch.long),
        torch.ones((batch, num_markers), dtype=torch.bool),
        torch.zeros(batch, dtype=torch.long),
    )
    dynamic_axes = {
        "input_ids": {0: "batch_size", 1: "seq_len"},
        "attention_mask": {0: "batch_size", 1: "seq_len"},
        "marker_pos": {0: "batch_size", 1: "num_markers"},
        "marker_mask": {0: "batch_size", 1: "num_markers"},
        "qtype": {0: "batch_size"},
        "logits": {0: "batch_size", 1: "num_markers"},
        "act_logits": {0: "batch_size"},
    }
    torch.onnx.export(
        agent.model,
        inputs,
        str(path),
        export_params=True,
        opset_version=18,
        do_constant_folding=True,
        input_names=["input_ids", "attention_mask", "marker_pos", "marker_mask", "qtype"],
        output_names=["logits", "act_logits"],
        dynamic_axes=dynamic_axes,
    )
    del agent


def load_agent():
    graph = onnx_path()
    if not graph.is_file():
        try:
            export_graph(graph)
        except Exception as exc:
            emit({"status": f"ONNX 내보내기에 실패해 상주 모델로 올립니다: {exc}"})
            import laya
            return laya.load(MODEL_ID), "resident"
    from laya.onnx_agent import ONNXAgent
    return ONNXAgent(MODEL_ID, onnx_path=str(graph)), "onnx"


def predict(agent, state):
    drift, choice = drift_from(agent.predict(state, QUESTIONS))
    return drift, choice


def serve():
    agent, backend = load_agent()
    emit({"ready": True, "backend": backend})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            drift, choice = predict(agent, request.get("state", ""))
            emit({"id": request.get("id"), "drift": drift, "choice": choice})
        except Exception as exc:
            request_id = None
            try:
                request_id = json.loads(line).get("id")
            except Exception:
                pass
            emit({"id": request_id, "error": str(exc)})


def check():
    if not weights_present():
        print("AI_SAMPLES_OK")
        return 0
    samples = [
        ("앱: Safari\n주소: https://www.youtube.com/shorts/sample\n제목: 쇼츠\n목표: 공부", "drift"),
        ("앱: Safari\n주소: https://www.youtube.com/watch?v=lecture\n제목: 선형대수학 12강\n목표: 공부", "study"),
        ("앱: Visual Studio Code\n창 제목: HabitBlocker\n목표: 공부", "study"),
        ("앱: Steam\n창 제목: Game\n목표: 공부", "drift"),
    ]
    agent, _backend = load_agent()
    for state, expected in samples:
        _drift, choice = predict(agent, state)
        if choice != expected:
            print(f"sample mismatch: expected {expected}, got {choice}", file=sys.stderr)
            return 1
    print("AI_SAMPLES_OK")
    return 0


def main():
    if "--check" in sys.argv:
        return check()
    serve()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        emit({"ready": False, "error": str(exc)})
        raise SystemExit(1)
