#!/usr/bin/env python3
import dataclasses
import json
import sys
from enum import Enum
from pathlib import Path
from typing import List

class TestStatus(Enum):
    """The test status enum."""
    PASSED = 1
    FAILED = 2
    SKIPPED = 3
    ERROR = 4

@dataclasses.dataclass
class TestResult:
    """The test result dataclass."""
    name: str
    status: TestStatus

### DO NOT MODIFY THE CODE ABOVE ###
### Implement the parsing logic below ###

def _enumerate_tests_as_failed() -> List[TestResult]:
    """
    Scan test files to enumerate all test names when pytest collection fails.
    Returns all discovered tests marked as FAILED.
    """
    import ast
    import os

    results = []
    # Look for tests directory in known container locations
    for candidate in ['/eval_assets/tests', 'tests']:
        if os.path.isdir(candidate):
            tests_dir = candidate
            break
    else:
        return results

    for filename in sorted(os.listdir(tests_dir)):
        if not filename.startswith('test_') or not filename.endswith('.py'):
            continue
        filepath = os.path.join(tests_dir, filename)
        rel_path = f"tests/{filename}"
        try:
            with open(filepath) as f:
                tree = ast.parse(f.read())
        except Exception:
            continue

        for node in ast.iter_child_nodes(tree):
            if isinstance(node, ast.ClassDef):
                for item in node.body:
                    if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name.startswith('test'):
                        test_name = f"{rel_path}::{node.name}::{item.name}"
                        results.append(TestResult(name=test_name, status=TestStatus.FAILED))
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith('test'):
                test_name = f"{rel_path}::{node.name}"
                results.append(TestResult(name=test_name, status=TestStatus.FAILED))

    return results


def parse_test_output(stdout_content: str, stderr_content: str) -> List[TestResult]:
    """
    Parse the test output content and extract test results.
    """
    import re
    results = []
    pattern = re.compile(r'^(\S+::\S+)\s+(PASSED|FAILED|SKIPPED|ERROR)', re.MULTILINE)

    for match in pattern.finditer(stdout_content):
        name = match.group(1)
        status = TestStatus[match.group(2)]
        results.append(TestResult(name=name, status=status))

    for match in pattern.finditer(stderr_content):
        name = match.group(1)
        if not any(r.name == name for r in results):
            status = TestStatus[match.group(2)]
            results.append(TestResult(name=name, status=status))

    # If no results parsed but stderr shows collection/import errors,
    # enumerate tests from the source files and mark them all FAILED
    if not results and ('ModuleNotFoundError' in stderr_content
                        or 'ImportError' in stderr_content
                        or 'ERROR collecting' in stderr_content):
        results = _enumerate_tests_as_failed()

    return results

### Implement the parsing logic above ###
### DO NOT MODIFY THE CODE BELOW ###

def export_to_json(results: List[TestResult], output_path: Path) -> None:
    json_results = {
        'tests': [
            {'name': result.name, 'status': result.status.name} for result in results
        ]
    }
    with open(output_path, 'w') as f:
        json.dump(json_results, f, indent=2)

def main(stdout_path: Path, stderr_path: Path, output_path: Path) -> None:
    with open(stdout_path) as f:
        stdout_content = f.read()
    with open(stderr_path) as f:
        stderr_content = f.read()

    results = parse_test_output(stdout_content, stderr_content)
    export_to_json(results, output_path)

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print('Usage: python parsing.py <stdout_file> <stderr_file> <output_json>')
        sys.exit(1)

    main(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))