"""
Multi-Model Content Pipeline with Ray Serve
=============================================

A single Ray Serve application with 4 independently-scaling deployments.

Why this architecture?
    Monolithic serving bundles all logic into one replica type, forcing every
    replica to carry the heaviest resource (GPU). By splitting into separate
    deployments, each tier gets exactly the resources it needs and scales to
    its own bottleneck — CPU business logic doesn't waste GPUs, and expensive
    GPU replicas aren't blocked by cheap validation work.

Deployments:
    1. ContentFilter      (CPU)      — validation, PII redaction
    2. SentimentClassifier (0.25 GPU) — DistilBERT sentiment analysis
    3. Summarizer          (0.25 GPU) — DistilBART-CNN summarization
    4. ContentPipeline     (CPU)      — FastAPI orchestrator

Usage:
    serve run serve_app:app                     # Local
    anyscale service deploy -f service.yaml     # Production
"""

import asyncio
import re
from typing import Any

from fastapi import FastAPI, Request
from ray import serve
from ray.serve.handle import DeploymentHandle


# -- Deployment 1: ContentFilter (CPU) ----------------------------------------
#
# WHY a separate deployment?
#   This is pure business logic — regex, string ops, validation. It runs on
#   CPU only and completes in ~1ms. Making it a separate deployment means:
#     • It never occupies a GPU slot.
#     • It acts as a cheap gate: rejected requests never reach the GPU
#       deployments, saving expensive compute.
#     • It can scale to 8 replicas under high volume without touching GPU
#       node capacity.
#
# WHY target_ongoing_requests=25?
#   Each request is ~1ms of CPU work, so a single replica can handle a huge
#   number of concurrent requests before becoming a bottleneck. A high target
#   keeps replica count low during normal traffic.


@serve.deployment(
    num_replicas="auto",
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 8,
        "target_ongoing_requests": 25,
    },
    ray_actor_options={"num_cpus": 1},
)
class ContentFilter:
    """CPU-only content gate: validation, blocklist, and PII redaction."""

    _MIN_LENGTH = 3
    _MAX_LENGTH = 10_000

    def __init__(self):
        # WHY compile patterns in __init__?
        #   Regex compilation is expensive relative to matching. By compiling
        #   once at startup, every subsequent .filter() call pays only the
        #   match cost — important when handling thousands of requests/sec.
        self.pii_patterns = {
            "email": re.compile(r"\b[\w.-]+@[\w.-]+\.\w+\b"),
            "phone": re.compile(r"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"),
            "ssn": re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
        }
        self.blocked_words = {"spam", "scam", "hack"}
        print("ContentFilter ready (CPU)")

    async def filter(self, text: str) -> dict[str, Any]:
        """Validate, check blocklist, and redact PII.

        WHY async?
            Ray Serve dispatches requests via an async event loop. Even though
            the work here is CPU-bound, declaring the method async lets the
            replica accept the next request immediately after yielding, keeping
            throughput high without thread-pool overhead.

        Returns:
            dict with "passed" bool. If True, includes "cleaned_text" and
            "pii_detected". If False, includes "reason".
        """
        # Fast-fail validations — cheapest checks first
        if not text or len(text.strip()) < self._MIN_LENGTH:
            return {"passed": False, "reason": "Text too short (min 3 chars)"}
        if len(text) > self._MAX_LENGTH:
            return {"passed": False, "reason": "Text too long (max 10,000 chars)"}

        lower_text = text.lower()
        for word in self.blocked_words:
            if word in lower_text:
                return {"passed": False, "reason": "Blocked content detected"}

        # PII redaction — iterate patterns and replace in-place
        cleaned = text
        pii_found: dict[str, int] = {}
        for pii_type, pattern in self.pii_patterns.items():
            matches = pattern.findall(cleaned)
            if matches:
                pii_found[pii_type] = len(matches)
                cleaned = pattern.sub(f"[{pii_type.upper()}_REDACTED]", cleaned)

        return {
            "passed": True,
            "cleaned_text": cleaned,
            "pii_detected": pii_found,
            "original_length": len(text),
        }


# -- Deployment 2: SentimentClassifier (fractional GPU) -----------------------
#
# WHY 0.25 GPU per replica?
#   DistilBERT is a small model (~67M params, ~250 MB VRAM). Allocating a full
#   GPU would waste 80%+ of the memory. Fractional GPU (0.25) lets Ray pack
#   4 SentimentClassifier replicas onto a single physical A10, maximizing
#   GPU utilization and reducing cost.
#
# WHY downscale_delay_s=300?
#   Loading the model + warm-up takes several seconds. A 5-minute cooldown
#   prevents replicas from being torn down and re-created during bursty traffic.
#
# WHY target_ongoing_requests=5?
#   Inference takes ~10ms per request. With 5 concurrent requests, a single
#   replica stays busy but doesn't queue excessively. If load exceeds this,
#   the autoscaler adds another replica (up to 4).


@serve.deployment(
    num_replicas="auto",
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 4,
        "target_ongoing_requests": 5,
        "downscale_delay_s": 300,
    },
    ray_actor_options={"num_gpus": 0.25, "num_cpus": 1},
)
class SentimentClassifier:
    """DistilBERT sentiment analysis on a fractional GPU."""

    _MODEL_ID = "distilbert-base-uncased-finetuned-sst-2-english"
    _MAX_INPUT_CHARS = 512

    def __init__(self):
        # WHY lazy import?
        #   `transformers` and `torch` are heavy (~2 GB). Importing at module
        #   level would slow down every deployment in this file. Lazy import
        #   means only SentimentClassifier replicas pay the import cost.
        from transformers import pipeline

        self.classifier = pipeline(
            "sentiment-analysis",
            model=self._MODEL_ID,
            device="cuda",
        )
        # WHY warm up?
        #   First inference triggers JIT compilation and CUDA kernel caching.
        #   A dummy call here moves that latency out of the request path.
        self.classifier("warmup")
        print("SentimentClassifier ready (GPU 0.25)")

    async def classify(self, text: str) -> dict[str, Any]:
        """Return sentiment label (POSITIVE/NEGATIVE) and confidence score.

        WHY asyncio.to_thread?
            The HuggingFace pipeline's __call__ is synchronous and holds the
            GIL during CPU pre/post-processing. Running it in a thread lets
            the event loop continue accepting new requests while this one
            waits for GPU inference to complete.
        """
        truncated = text[: self._MAX_INPUT_CHARS]
        result = await asyncio.to_thread(self.classifier, truncated)
        prediction = result[0]
        return {
            "label": prediction["label"],
            "score": round(prediction["score"], 4),
        }


# -- Deployment 3: Summarizer (fractional GPU) --------------------------------
#
# WHY distilbart-cnn-12-6?
#   1. UNGATED — no HuggingFace token required. Downloads instantly.
#   2. TINY — only ~1.2 GB. Loads in seconds, uses minimal VRAM.
#   3. PURPOSE-BUILT for summarization (fine-tuned on CNN/DailyMail).
#   4. No vLLM needed — runs via standard HuggingFace pipeline.
#
# WHY 0.25 GPU?
#   The model is small enough to share a GPU with SentimentClassifier.
#   4 replicas (2 sentiment + 2 summarizer) can fit on a single GPU.


@serve.deployment(
    num_replicas="auto",
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 4,
        "target_ongoing_requests": 3,
        "downscale_delay_s": 300,
    },
    ray_actor_options={"num_gpus": 0.25, "num_cpus": 1},
)
class Summarizer:
    """Text summarization via DistilBART-CNN (ungated, lightweight)."""

    _MODEL_ID = "sshleifer/distilbart-cnn-12-6"
    _MAX_INPUT_CHARS = 1024

    def __init__(self):
        # Transformers v5+ removed pipeline("summarization"); use seq2seq model directly.
        from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
        import torch

        self._device = "cuda" if torch.cuda.is_available() else "cpu"
        self._tokenizer = AutoTokenizer.from_pretrained(self._MODEL_ID)
        self._model = AutoModelForSeq2SeqLM.from_pretrained(self._MODEL_ID).to(
            self._device
        )
        # Warmup (same as old pipeline)
        self._summarize_sync("warmup text for the summarizer model to cache kernels.")
        print("Summarizer ready (GPU 0.25)")

    def _summarize_sync(
        self,
        text: str,
        max_length: int = 130,
        min_length: int = 30,
        do_sample: bool = False,
    ) -> list[dict[str, str]]:
        """Run summarization; returns list of dicts with 'summary_text' (pipeline-compatible)."""
        inputs = self._tokenizer(
            text,
            return_tensors="pt",
            truncation=True,
            max_length=1024,
        ).to(self._device)
        out = self._model.generate(
            **inputs,
            max_length=max_length,
            min_length=min_length,
            do_sample=do_sample,
            num_beams=4,
        )
        summary_text = self._tokenizer.decode(out[0], skip_special_tokens=True)
        return [{"summary_text": summary_text}]

    async def summarize(self, text: str) -> dict[str, Any]:
        """Generate a concise summary using DistilBART-CNN."""
        truncated = text[: self._MAX_INPUT_CHARS]
        result = await asyncio.to_thread(
            self._summarize_sync,
            truncated,
            130,
            30,
            False,
        )
        summary = result[0]["summary_text"]

        return {
            "summary": summary,
            "input_length": len(text),
            "output_tokens": len(summary.split()),
        }


# -- Deployment 4: ContentPipeline (CPU orchestrator / ingress) ----------------
#
# WHY a separate orchestrator instead of putting logic in a single deployment?
#   The orchestrator is pure async coordination — it awaits handles, not GPUs.
#   Separating it means:
#     • It runs on cheap CPU nodes (no GPU waste).
#     • It can scale to 5 replicas to absorb connection bursts.
#     • It controls the execution order: filter FIRST (cheap gate), then
#       fan out to GPU models ONLY if content passes.
#
# WHY target_ongoing_requests=30?
#   The orchestrator spends almost all its time awaiting downstream RPCs.
#   It has very little CPU overhead per request, so a single replica can
#   coordinate 30 concurrent pipelines before needing help.

fastapi_app = FastAPI(
    title="Multi-Model Content Pipeline",
    description="Demonstrates independent scaling of CPU logic, small GPU model, and LLM",
)


@serve.deployment(
    num_replicas="auto",
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 5,
        "target_ongoing_requests": 30,
    },
    ray_actor_options={"num_cpus": 1},
)
@serve.ingress(fastapi_app)
class ContentPipeline:
    """FastAPI ingress that orchestrates the full analysis pipeline.

    WHY @serve.ingress(fastapi_app)?
        This decorator turns the class into the HTTP entry point. FastAPI gives
        us automatic request validation, OpenAPI docs at /docs, and native
        async support — all without a separate web server process.

    Request flow:
        Client → ContentPipeline → ContentFilter (CPU)
                                 → SentimentClassifier (GPU) ──┐ (parallel)
                                 → LLMSummarizer (GPU)     ────┘
                                 → Combined response
    """

    def __init__(
        self,
        content_filter: DeploymentHandle,
        sentiment_classifier: DeploymentHandle,
        llm_summarizer: DeploymentHandle,
    ):
        # WHY DeploymentHandle instead of direct function calls?
        #   Each handle is a Ray Serve RPC stub. Calling .remote() sends the
        #   request to any available replica of that deployment — Ray Serve
        #   handles load balancing, replica discovery, and fault tolerance.
        self.content_filter = content_filter
        self.sentiment_classifier = sentiment_classifier
        self.llm_summarizer = llm_summarizer
        print("ContentPipeline orchestrator ready (CPU)")

    @fastapi_app.post("/analyze")
    async def analyze(self, request: Request) -> dict[str, Any]:
        """Full analysis pipeline: filter → sentiment + summarization (parallel).

        WHY this order?
            1. Filter first — it's ~1ms CPU work. If content is rejected, we
               skip GPU inference entirely. This is a cost optimization: one
               cheap CPU call can save two expensive GPU calls.
            2. Sentiment + summary in parallel — these are independent operations
               on different GPU deployments. Running them sequentially would
               double the end-to-end latency for no reason.
        """
        data = await request.json()
        text = data.get("text", "")

        # Step 1: Cheap CPU gate — reject bad content before GPU work
        filter_result = await self.content_filter.filter.remote(text)
        if not filter_result["passed"]:
            return {"status": "rejected", "reason": filter_result["reason"]}

        cleaned_text = filter_result["cleaned_text"]

        # Step 2: Fan out to GPU models in parallel via asyncio.gather
        # WHY asyncio.gather instead of sequential awaits?
        #   Sentiment (~10ms) and summarization (~3s) run on different
        #   deployments with different replica pools. gather() dispatches
        #   both RPCs immediately; total latency = max(sentiment, summary)
        #   instead of sentiment + summary.
        sentiment_ref = self.sentiment_classifier.classify.remote(cleaned_text)
        summary_ref = self.llm_summarizer.summarize.remote(cleaned_text)
        sentiment_result, summary_result = await asyncio.gather(
            sentiment_ref, summary_ref
        )

        # Step 3: Merge and return
        return {
            "status": "processed",
            "filter": {
                "pii_detected": filter_result["pii_detected"],
                "original_length": filter_result["original_length"],
            },
            "sentiment": sentiment_result,
            "summary": summary_result,
        }

    @fastapi_app.get("/health")
    async def health(self) -> dict[str, str]:
        """Health check — used by load balancers and Anyscale service probes."""
        return {"status": "healthy"}


# -- Bind: wire the deployment dependency graph --------------------------------
#
# WHY .bind() instead of instantiating classes directly?
#   .bind() defines the deployment graph at import time without starting any
#   replicas. At runtime, Ray Serve:
#     1. Creates replica actors for each deployment
#     2. Injects DeploymentHandle references as constructor args
#     3. Starts autoscalers for each deployment independently
#
#   This is Ray Serve's dependency injection — it decouples deployment
#   definition from deployment execution.

app = ContentPipeline.bind(
    content_filter=ContentFilter.bind(),
    sentiment_classifier=SentimentClassifier.bind(),
    llm_summarizer=Summarizer.bind(),
)
