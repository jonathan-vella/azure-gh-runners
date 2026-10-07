import hashlib
import os
import stat
import urllib.error
import urllib.request


TOKEN_URL = (
    "http://169.254.169.254/metadata/identity/oauth2/token"
    "?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F"
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def assert_canaries_absent(environment, expected_hashes):
    for value in environment.values():
        value_hash = hashlib.sha256(value.encode()).hexdigest()
        require(
            value_hash not in expected_hashes,
            "synthetic canary value is present in the container environment",
        )


def assert_environment_isolated(environment):
    require(
        "IDENTITY_ENDPOINT" not in environment and "IDENTITY_HEADER" not in environment,
        "managed identity endpoint environment is available",
    )
    require("APP_KEY" not in environment, "app key environment variable is available")
    assert_canaries_absent(
        environment,
        {
            environment["EXPECTED_APP_KEY_SHA256"],
            environment["EXPECTED_SCALE_AUTH_SHA256"],
        },
    )


def assert_metadata_token_denied(open_url=urllib.request.urlopen):
    try:
        response = open_url(TOKEN_URL, timeout=2)
        response.close()
    except urllib.error.HTTPError as error:
        require(
            not 200 <= error.code < 300,
            "managed identity token request unexpectedly succeeded",
        )
    except (urllib.error.URLError, TimeoutError):
        return
    else:
        raise RuntimeError("managed identity token request unexpectedly succeeded")


def run(handoff_path="/jit/config", environment=None, open_url=urllib.request.urlopen):
    environment = os.environ if environment is None else environment
    require(os.getuid() == 65532, "main UID check failed")

    info = os.stat(handoff_path)
    require(
        info.st_uid == 65532
        and info.st_gid == 65532
        and stat.S_IMODE(info.st_mode) == 0o400,
        "handoff ownership or mode check failed",
    )
    with open(handoff_path, "rb") as handoff_file:
        content = handoff_file.read()
    content_hash = hashlib.sha256(content).hexdigest()
    require(
        content_hash == environment["EXPECTED_JIT_SHA256"],
        "handoff content check failed",
    )

    assert_environment_isolated(environment)
    assert_metadata_token_denied(open_url)

    os.unlink(handoff_path)
    require(not os.path.exists(handoff_path), "handoff file was not deleted")

    print("ASSERT_main_uid_65532=true")
    print("ASSERT_emptydir_shared_readable_deletable=true")
    print("ASSERT_jit_file_mode_0400=true")
    print("ASSERT_identity_environment_absent=true")
    print("ASSERT_identity_token_request_denied=true")
    print("ASSERT_app_key_and_scale_canaries_absent_main=true")


if __name__ == "__main__":
    run()
