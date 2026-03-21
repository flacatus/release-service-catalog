import os
import sys
import json
import textwrap
import subprocess
from unittest.mock import patch, MagicMock
import pytest

@pytest.fixture
def script_env(tmp_path):
    script_content = textwrap.dedent(r'''#!/usr/bin/env python3
import json
import os
import sys
import time
import base64
import requests
import subprocess

EXPIRE_MINUTES_AS_SECONDS = int(os.environ.get('GITHUBAPP_TOKEN_EXPIRATION_MINUTES', 10)) * 60
# TODO support github enteprise
GITHUB_API_URL = os.environ.get('GITHUB_API_URL')

# Fetch targetGHRepo, githubAppID, and githubAppInstallationID from data JSON file
with open(os.environ.get('DATA_JSON_PATH'), 'r') as f:
    data = json.load(f)
    target_gh_repo = data.get(
        'targetGHRepo',
        os.environ.get('DEFAULT_TARGET_GH_REPO')
    )
    github_app_id = str(data.get(
        'githubAppID',
        os.environ.get('DEFAULT_GITHUB_APP_ID')
    ))
    github_app_installation_id = str(data.get(
        'githubAppInstallationID',
        os.environ.get('DEFAULT_GITHUB_APP_INSTALLATION_ID')
    ))
    os.environ['TARGET_GH_REPO'] = target_gh_repo
    os.environ['GITHUBAPP_APP_ID'] = github_app_id
    os.environ['GITHUBAPP_INSTALLATION_ID'] = github_app_installation_id

with open('originRepo.txt', 'r') as fileA:
  originRepo = fileA.read().rstrip()
with open('revision.txt', 'r') as fileB:
  revision = fileB.read().rstrip()

class GitHub():
    token = None

    def __init__(self, private_key_path, app_id=None, installation_id=None):
        self._private_key_path = private_key_path
        self.app_id = app_id
        self.token = self._get_token(installation_id)

    def _app_token(self, expire_in=EXPIRE_MINUTES_AS_SECONDS):
      # based on https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/
      # generating-a-json-web-token-jwt-for-a-github-app#example-using-bash-to-generate-a-jwt

        now = int(time.time())

        header_ = {"typ": "JWT", "alg": "RS256"}
        # JWT requires base64url encoding without padding
        header = base64.urlsafe_b64encode(json.dumps(header_).encode()).rstrip(b'=')

        payload_ = {"iat": now, "exp": now + expire_in, "iss": self.app_id}
        payload = base64.urlsafe_b64encode(json.dumps(payload_).encode()).rstrip(b'=')

        header_payload = header + b"." + payload
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self._private_key_path],
            input=header_payload,
            check=True,
            stdout=subprocess.PIPE,
        )
        signature = base64.urlsafe_b64encode(proc.stdout).rstrip(b'=')

        token = header_payload + b"." + signature
        return token.decode()

    def _get_token(self, installation_id=None):
        app_token = self._app_token()
        if not installation_id:
            return app_token

        req = self._request(
            "POST",
            f"/app/installations/{installation_id}/access_tokens",
            headers={
                "Authorization": f"Bearer {app_token}",
                "Accept": "application/vnd.github.machine-man-preview+json"
            })

        ret = req.json()
        if 'token' not in ret:
            raise Exception(f"Authentication errors: {ret}")

        return ret['token']

    def _request(self, method, url, headers={}, data={}):
        if self.token and 'Authorization' not in headers:
            headers.update({"Authorization": "Bearer " + self.token})
        if not url.startswith("http"):
            url = f"{GITHUB_API_URL}{url}"
        return requests.request(method,
                                url,
                                headers=headers,
                                data=json.dumps(data))

    def create_mr(self):
        repo_name = originRepo.split('/')[-1]
        target_gh_repo = os.environ.get('TARGET_GH_REPO')
        req = self._request(
            "POST",
            f"/repos/{target_gh_repo}/pulls",
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github.v3+json"
            },
            data={
                "head": repo_name,
                "base": "main",
                "title": f"{repo_name} update",
                "maintainer_can_modify": False
            })
        json_output = req.json()
        print(json_output)
        return json_output

    def create_reset_branch(self):
        # Reset branch to main (no push yet). We will force-push once after adding this run's changes.
        branch = originRepo.split('/')[-1]
        target_gh_repo = os.environ.get('TARGET_GH_REPO')
        target_branch = self._request("GET", f"/repos/{target_gh_repo}/git/refs/heads/{branch}").json()
        main_branch_sha = self._request("GET", f"/repos/{target_gh_repo}/git/refs/heads/main")\
                          .json()['object']['sha']
        if "ref" in target_branch:
            # update branch
            self._request(
                "PATCH",
                f"/repos/{target_gh_repo}/git/refs/heads/{branch}",
                data={"sha": main_branch_sha, "force": True}
            )
        else:
            # create branch
            self._request(
                "POST",
                f"/repos/{target_gh_repo}/git/refs",
                data={"sha": main_branch_sha, "ref": f"refs/heads/{branch}"}
            )

    def force_push_changes(self):
        # We use git in the clone instead of the GitHub Contents API so we get one commit per run.
        # The Contents API creates one commit per PUT (one per file); there is no way to batch
        # multiple file changes into a single commit. One commit per run keeps the PR history clean
        # and the same PR stays open (we only force-push this single commit after resetting the branch).
        branch = originRepo.split('/')[-1]
        target_gh_repo = os.environ.get('TARGET_GH_REPO')
        repo_url = f"https://x-access-token:{self.token}@github.com/{target_gh_repo}.git"
        subprocess.run(["git", "-C", "cloned", "remote", "set-url", "origin", repo_url], check=True)
        subprocess.run(["git", "-C", "cloned", "checkout", "-b", branch], check=True)
        with open("updated_files.txt", "r") as f:
            for line in f:
                path = line.strip()
                if path:
                    subprocess.run(["git", "-C", "cloned", "add", path], check=True)
        subprocess.run(
            ["git", "-C", "cloned", "-c", "user.email=release-service@redhat.com", "-c",
             "user.name=release-service", "commit", "-m", "Update from release-service"],
            check=True
        )
        subprocess.run(["git", "-C", "cloned", "push", "--force", "origin", branch], check=True)

    def get_pr(self):
        repo_name = originRepo.split('/')[-1]
        target_gh_repo = os.environ.get('TARGET_GH_REPO')
        req = self._request(
            "GET",
            f"/repos/{target_gh_repo}/pulls",
            headers={
                "Accept": "application/vnd.github.v3+json"
            })
        json_output = req.json()
        for item in json_output:
            if item["user"]["login"].endswith("[bot]") and item["head"]["ref"] == repo_name:
                return item

    def get_pr_url_from_sha(self, sha):
        req = self._request(
            "GET",
            f"/search/issues?q={sha}",
            headers={
                "Accept": "application/vnd.github.v3+json"
            })
        return req.json()["items"][0]["pull_request"]["html_url"]

    def update_mr_description(self, pr_url, description):
        req = self._request(
            "PATCH",
            pr_url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github.v3+json"
            },
            data={ "body": description })
        json_output = req.json()
        print(json_output)

def main():

    with open("updated_files.txt", 'r') as ufiles:
        updated_files = len(ufiles.readlines())
    print('Total Number of updated files: ', updated_files)
    if updated_files == 0:
        print("No files to add to a PR. exiting...")
        sys.exit()

    key_path = os.environ.get('GITHUBAPP_KEY_PATH')

    if os.environ.get('GITHUBAPP_APP_ID'):
        app_id = os.environ['GITHUBAPP_APP_ID']
    else:
        raise Exception("application id is not set")

    print(f"Getting user token for application_id: {app_id}")
    github_app = GitHub(
        private_key_path=key_path,
        app_id=app_id,
        installation_id=os.environ.get('GITHUBAPP_INSTALLATION_ID'))

    github_app.create_reset_branch()
    github_app.force_push_changes()
    infra_pr = github_app.create_mr()
    if "url" not in infra_pr:
        infra_pr = github_app.get_pr()
    if "body" in infra_pr:
        description = infra_pr["body"]
        if description is None:
            description = "Included PRs:"
        new_pr_link = github_app.get_pr_url_from_sha(revision)
        new_description = f"{description}\r\n- {new_pr_link}"
        github_app.update_mr_description(infra_pr["url"], new_description)
    else:
        if "message" in infra_pr:
            print(infra_pr["message"])
        raise Exception("PR not created or did not already exist")

if __name__ == '__main__':
    main()
''')

    mock_code = textwrap.dedent(r'''
import sys
import os
import json
import subprocess
import requests
from unittest.mock import MagicMock

orig_run = subprocess.run
def mock_run(args, **kwargs):
    if args[0] == 'openssl':
        m = MagicMock()
        m.stdout = b'dummy_signature'
        m.returncode = 0
        return m
    elif args[0] == 'git':
        m = MagicMock()
        m.returncode = 0
        return m
    return orig_run(args, **kwargs)

subprocess.run = mock_run

def mock_request(method, url, **kwargs):
    m = MagicMock()
    resp = {}
    
    if "access_tokens" in url:
        if os.environ.get("MOCK_TOKEN_ERROR") == "1":
            resp = {"error": "bad"}
        else:
            resp = {"token": "mock_token"}
            
    elif method == "GET" and "/git/refs/heads/" in url and not url.endswith("/main"):
        if os.environ.get("MOCK_REF_EXISTS") == "1":
            resp = {"ref": "refs/heads/branch"}
        else:
            resp = {}
            
    elif method == "GET" and url.endswith("/main"):
        resp = {"object": {"sha": "main_sha"}}
        
    elif method == "POST" and "/pulls" in url:
        if os.environ.get("MOCK_PR_CREATE_FAIL") == "1":
            resp = {"message": "Validation Failed"}
        else:
            resp = {"url": "https://api.github.com/repos/org/repo/pulls/1", "body": os.environ.get("MOCK_PR_BODY", "Included PRs:")}
            if os.environ.get("MOCK_PR_BODY_NONE") == "1":
                resp["body"] = None
            if os.environ.get("MOCK_PR_NO_BODY") == "1":
                del resp["body"]
            if os.environ.get("MOCK_PR_HAS_MESSAGE") == "1":
                resp["message"] = "Some message"
                
    elif method == "GET" and "/pulls" in url:
        if os.environ.get("MOCK_GET_PR_MATCH") == "1":
            resp = [{
                "user": {"login": "app[bot]"},
                "head": {"ref": "myrepo"},
                "url": "https://api.github.com/repos/org/repo/pulls/1",
                "body": "Existing PR"
            }]
        else:
            resp = [{
                "user": {"login": "other"},
                "head": {"ref": "other"}
            }]
            
    elif method == "GET" and "/search/issues" in url:
        resp = {"items": [{"pull_request": {"html_url": "http://pr_link"}}]}
        
    m.json.return_value = resp
    return m

requests.request = mock_request
''')

    full_script = mock_code + "\n" + script_content
    script_file = tmp_path / "script.py"
    script_file.write_text(full_script)

    data_json_path = tmp_path / "data.json"
    data_json_path.write_text(json.dumps({
        "targetGHRepo": "org/repo",
        "githubAppID": "12345",
        "githubAppInstallationID": "67890"
    }))

    key_path = tmp_path / "private-key"
    key_path.write_text("dummy-key")

    env = os.environ.copy()
    env["GITHUBAPP_KEY_PATH"] = str(key_path)
    env["GITHUB_API_URL"] = "https://api.github.com"
    env["DATA_JSON_PATH"] = str(data_json_path)
    env["DEFAULT_TARGET_GH_REPO"] = "default/repo"
    env["DEFAULT_GITHUB_APP_ID"] = "111"
    env["DEFAULT_GITHUB_APP_INSTALLATION_ID"] = "222"

    (tmp_path / "originRepo.txt").write_text("https://github.com/org/myrepo")
    (tmp_path / "revision.txt").write_text("abcdef123456")
    (tmp_path / "updated_files.txt").write_text("file1.txt\nfile2.txt\n")

    return script_file, env, tmp_path

def run_script(script_file, env, cwd):
    cmd = [sys.executable, str(script_file)]
    result = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=cwd, timeout=30)
    return result.returncode, result.stdout, result.stderr

class TestHappyPath:
    def test_success_create_pr(self, script_env):
        script_file, env, tmp_path = script_env
        env["MOCK_REF_EXISTS"] = "1"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0
        assert "Total Number of updated files:  2" in stdout
        assert "Getting user token for application_id: 12345" in stdout

    def test_success_create_branch(self, script_env):
        script_file, env, tmp_path = script_env
        env["MOCK_REF_EXISTS"] = "0"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0

    def test_success_existing_pr(self, script_env):
        script_file, env, tmp_path = script_env
        env["MOCK_PR_CREATE_FAIL"] = "1"
        env["MOCK_GET_PR_MATCH"] = "1"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0

class TestEdgeCases:
    def test_no_updated_files(self, script_env):
        script_file, env, tmp_path = script_env
        (tmp_path / "updated_files.txt").write_text("")
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0
        assert "Total Number of updated files:  0" in stdout
        assert "No files to add to a PR. exiting..." in stdout

    def test_empty_line_in_updated_files(self, script_env):
        script_file, env, tmp_path = script_env
        (tmp_path / "updated_files.txt").write_text("file1.txt\n\nfile2.txt\n")
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0
        assert "Total Number of updated files:  3" in stdout

    def test_no_installation_id(self, script_env):
        script_file, env, tmp_path = script_env
        data_json_path = tmp_path / "data.json"
        data_json_path.write_text(json.dumps({
            "targetGHRepo": "org/repo",
            "githubAppID": "12345",
            "githubAppInstallationID": ""
        }))
        env["DEFAULT_GITHUB_APP_INSTALLATION_ID"] = ""
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0

    def test_pr_body_none(self, script_env):
        script_file, env, tmp_path = script_env
        env["MOCK_PR_BODY_NONE"] = "1"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0

    def test_fallback_target_gh_repo(self, script_env):
        script_file, env, tmp_path = script_env
        data_json_path = tmp_path / "data.json"
        data_json_path.write_text(json.dumps({
            "githubAppID": "12345",
            "githubAppInstallationID": "67890"
        }))
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0

    def test_custom_expiration(self, script_env):
        script_file, env, tmp_path = script_env
        env["GITHUBAPP_TOKEN_EXPIRATION_MINUTES"] = "20"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 0

class TestErrorPaths:
    def test_token_error(self, script_env):
        script_file, env, tmp_path = script_env
        env["MOCK_TOKEN_ERROR"] = "1"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 1
        assert "Authentication errors:" in stderr or "Authentication errors:" in stdout

    def test_missing_app_id(self, script_env):
        script_file, env, tmp_path = script_env
        data_json_path = tmp_path / "data.json"
        data_json_path.write_text(json.dumps({
            "targetGHRepo": "org/repo",
            "githubAppID": "",
            "githubAppInstallationID": "67890"
        }))
        env["DEFAULT_GITHUB_APP_ID"] = ""
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 1
        assert "application id is not set" in stderr or "application id is not set" in stdout

    def test_pr_not_created_no_body_with_message(self, script_env):
        script_file, env, tmp_path = script_env
        env["MOCK_PR_NO_BODY"] = "1"
        env["MOCK_PR_HAS_MESSAGE"] = "1"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 1
        assert "Some message" in stdout
        assert "PR not created or did not already exist" in stderr or "PR not created or did not already exist" in stdout

    def test_pr_not_created_no_body_no_message(self, script_env):
        script_file, env, tmp_path = script_env
        env["MOCK_PR_NO_BODY"] = "1"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 1
        assert "PR not created or did not already exist" in stderr or "PR not created or did not already exist" in stdout

    def test_pr_create_fail_and_no_existing_pr(self, script_env):
        script_file, env, tmp_path = script_env
        env["MOCK_PR_CREATE_FAIL"] = "1"
        env["MOCK_GET_PR_MATCH"] = "0"
        returncode, stdout, stderr = run_script(script_file, env, tmp_path)
        assert returncode == 1
        assert "TypeError" in stderr