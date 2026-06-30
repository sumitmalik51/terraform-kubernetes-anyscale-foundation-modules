"""
Test client for the Multi-Model Content Pipeline.

Usage:
    # Against local dev server (serve run serve_app:app)
    python client.py

    # Against Anyscale service
    python client.py --url https://your-service-url.anyscale.com --token YOUR_TOKEN
"""

import argparse
import concurrent.futures
import json
import time

import requests

# -- Test cases for the /analyze endpoint -------------------------------------

ANALYZE_TEST_CASES = [
    {
        "name": "Normal text (should pass all stages)",
        "payload": {
            "text": (
                "Ray Serve makes it easy to deploy multiple ML models as a single "
                "application. Each deployment scales independently based on its own "
                "load profile — CPU-bound business logic, lightweight GPU models, and "
                "heavy LLM inference all coexist without interfering with each other. "
                "This composability is a key advantage over monolithic serving frameworks."
            )
        },
    },
    {
        "name": "Text with PII (should redact and proceed)",
        "payload": {
            "text": (
                "Please contact John at john.doe@example.com or call 555-123-4567 "
                "for more information about the quarterly earnings report. The company "
                "exceeded revenue expectations by 15% this quarter."
            )
        },
    },
    {
        "name": "Blocked content (should be rejected)",
        "payload": {"text": "This is a spam message trying to scam people."},
    },
    {
        "name": "Too-short text (should be rejected)",
        "payload": {"text": "Hi"},
    },
]


def _print_banner(title: str) -> None:
    """Print a section banner."""
    print(f"\n{'=' * 60}")
    print(title)
    print("=" * 60)


def _print_response(response: requests.Response) -> None:
    """Print status code and formatted JSON body."""
    print(f"Status: {response.status_code}")
    print(json.dumps(response.json(), indent=2))


def test_health(base_url: str, headers: dict) -> None:
    """Test the health endpoint."""
    _print_banner("HEALTH CHECK")
    response = requests.get(f"{base_url}/health", headers=headers)
    _print_response(response)


def test_analyze(base_url: str, headers: dict) -> None:
    """Run all analysis test cases."""
    for i, case in enumerate(ANALYZE_TEST_CASES, start=1):
        _print_banner(f"TEST {i}: {case['name']}")
        response = requests.post(
            f"{base_url}/analyze",
            headers=headers,
            json=case["payload"],
        )
        _print_response(response)


def test_throughput(
    base_url: str, headers: dict, num_requests: int = 10
) -> None:
    """Send concurrent requests to observe independent scaling."""
    _print_banner(f"THROUGHPUT TEST: {num_requests} concurrent requests")

    payload = {
        "text": (
            "Artificial intelligence is transforming industries from healthcare to "
            "finance. Machine learning models can now process vast amounts of data "
            "to make predictions, automate decisions, and generate content."
        )
    }

    def send_request(i: int) -> tuple[int, int, float]:
        start = time.time()
        resp = requests.post(
            f"{base_url}/analyze", headers=headers, json=payload
        )
        return i, resp.status_code, time.time() - start

    overall_start = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_requests) as pool:
        futures = [pool.submit(send_request, i) for i in range(num_requests)]
        results = [f.result() for f in concurrent.futures.as_completed(futures)]
    overall_elapsed = time.time() - overall_start

    for i, status, elapsed in sorted(results):
        print(f"  Request {i:2d}: status={status}, latency={elapsed:.2f}s")

    print(f"\n  Total wall-clock time: {overall_elapsed:.2f}s")
    print(f"  Effective throughput:  {num_requests / overall_elapsed:.1f} req/s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Test Multi-Model Content Pipeline"
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8000",
        help="Base URL of the service (default: http://localhost:8000)",
    )
    parser.add_argument(
        "--token",
        default=None,
        help="Auth token for Anyscale service (optional)",
    )
    parser.add_argument(
        "--throughput",
        type=int,
        default=0,
        help="Run throughput test with N concurrent requests (default: skip)",
    )
    args = parser.parse_args()

    headers = {"Content-Type": "application/json"}
    if args.token:
        headers["Authorization"] = f"Bearer {args.token}"

    test_health(args.url, headers)
    test_analyze(args.url, headers)

    if args.throughput > 0:
        test_throughput(args.url, headers, args.throughput)
