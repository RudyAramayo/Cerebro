#!/usr/bin/env python3
"""Exercise Cerebro's SSH arguments with real OpenSSH host-key handshakes.

The fixture compiles the production task factory, substituting only sshpass
discovery. OpenSSH talks to a temporary sshd through pipes, never the network.
Authentication is disabled; no remote command runs and no real known_hosts or
credentials are read or changed. Requires macOS Xcode tools and bundled sshd.
"""

import getpass
import json
from pathlib import Path
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
#import "ROBSystemDependencyManager.h"

@interface SSHFixtureManager : ROBSystemDependencyManager
@end
@implementation SSHFixtureManager
- (NSString *)sshpassPath { return @"/usr/bin/true"; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        for (int index = 1; index < argc; index++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
        }
        NSError *error = nil;
        NSTask *task = [[SSHFixtureManager new]
            newSSHpassTaskWithSSHArguments:arguments error:&error];
        if (task == nil) {
            NSLog(@"Task factory failed: %@", error);
            return 1;
        }
        // Only remove sshpass's password-pipe prefix; execute the exact SSH
        // binary and arguments created by the production factory below.
        NSArray *ssh = [task.arguments subarrayWithRange:
            NSMakeRange(2, task.arguments.count - 2)];
        NSData *json = [NSJSONSerialization dataWithJSONObject:ssh options:0 error:&error];
        if (json == nil) return 1;
        [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
    }
    return 0;
}
'''


def run(arguments):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=30)


def main():
    with tempfile.TemporaryDirectory(prefix="cerebro-ssh-fixtures-") as temporary:
        directory = Path(temporary)
        harness = directory / "factory.m"
        harness.write_text(HARNESS)
        factory = directory / "factory"
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
            "-I", str(ROOT / "Cerebro"), str(harness),
            str(ROOT / "Cerebro/ROBSystemDependencyManager.m"), "-o", str(factory),
        ], check=True, timeout=120)

        keys = [directory / "original_key", directory / "replacement_key"]
        for key in keys:
            subprocess.run([
                "/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key),
            ], check=True, timeout=15)

        config = directory / "sshd_config"
        known_hosts = directory / "known_hosts"

        def select_host_key(key):
            config.write_text(
                f"HostKey {key}\nUsePAM no\nPasswordAuthentication no\n"
                "PubkeyAuthentication no\nKbdInteractiveAuthentication no\nLogLevel ERROR\n"
            )

        select_host_key(keys[0])
        arguments = [
            "-F", "/dev/null", "-T", "-o", "BatchMode=yes",
            "-o", "IdentityFile=none", "-o", "IdentityAgent=none",
            "-o", f"UserKnownHostsFile={known_hosts}",
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UpdateHostKeys=no",
            "-o", "ProxyCommand=" + shlex.join([
                "/usr/sbin/sshd", "-i", "-e", "-f", str(config),
            ]),
            getpass.getuser() + "@cerebro-amber-host-key-fixture.invalid", "true",
        ]
        result = run([str(factory), *arguments])
        assert result.returncode == 0, result.stderr
        ssh = json.loads(result.stdout)

        first = run(ssh)
        assert first.returncode == 255 and "Permission denied" in first.stderr, first.stderr
        assert known_hosts.exists(), "First-time host key was not saved"
        remembered = known_hosts.read_bytes()
        public_key = keys[0].with_suffix(".pub").read_text().split()[1].encode()
        assert public_key in remembered, "Saved key does not match the SSH server"

        second = run(ssh)
        assert second.returncode == 255 and "Permission denied" in second.stderr, second.stderr
        assert known_hosts.read_bytes() == remembered, "Remembered host key was rewritten"

        select_host_key(keys[1])
        changed = run(ssh)
        assert changed.returncode == 255, changed.stderr
        assert "REMOTE HOST IDENTIFICATION HAS CHANGED" in changed.stderr, changed.stderr
        assert "Host key verification failed" in changed.stderr, changed.stderr
        assert "Permission denied" not in changed.stderr, "Changed host reached authentication"
        assert known_hosts.read_bytes() == remembered, "Changed key overwrote the trusted key"

    print("Amber SSH fixtures passed: new key saved, known key reused, changed key rejected")


if __name__ == "__main__":
    main()
