#!/bin/bash
# 老式算法测试 sshd(issue #12 堡垒机 KEX 兼容回归):
# 模拟阿里云等堡垒机的算法集 —— 只开 DH group14 KEX + aes-ctr + RSA host key,
# 现代算法(curve25519/ECDH、AES-GCM、ed25519 host key)全部关闭。
# 监听 127.0.0.1:2224,与常规 test sshd(2222)并存。
# 用法: ./up-legacy.sh [sha1]   停止: docker rm -f berth-test-legacy
#   无参数: diffie-hellman-group14-sha256 + rsa-sha2-512/256(常见堡垒机)
#   sha1:   diffie-hellman-group14-sha1 + ssh-rsa(极端遗留栈)
set -euo pipefail

MODE="${1:-sha2}"

docker rm -f berth-test-legacy >/dev/null 2>&1 || true
docker run -d --name berth-test-legacy \
  -p 127.0.0.1:2224:2222 \
  -e PASSWORD_ACCESS=true \
  -e USER_NAME=dev \
  -e USER_PASSWORD=berth-legacy \
  lscr.io/linuxserver/openssh-server:latest >/dev/null

# 等 sshd 起来后收紧算法(镜像 init 每次启动重写 sshd_config,不能 docker restart,
# 改完 SIGHUP 原地重读;见 up-kbdint.sh 的同款说明)。
sleep 3
if [ "$MODE" = "sha1" ]; then
  KEX="diffie-hellman-group14-sha1"
  HKA="ssh-rsa"
else
  KEX="diffie-hellman-group14-sha256"
  HKA="rsa-sha2-512,rsa-sha2-256"
fi
docker exec berth-test-legacy sh -c "
  CONF=/config/sshd/sshd_config
  [ -f /config/ssh_host_keys/ssh_host_rsa_key ] || ssh-keygen -t rsa -b 2048 -N '' -f /config/ssh_host_keys/ssh_host_rsa_key -q
  sed -i '/^HostKey /d' \"\$CONF\"
  {
    echo 'HostKey /config/ssh_host_keys/ssh_host_rsa_key'
    echo 'KexAlgorithms $KEX'
    echo 'HostKeyAlgorithms $HKA'
    echo 'Ciphers aes128-ctr'
    echo 'MACs hmac-sha2-256'
  } >> \"\$CONF\"
  kill -HUP \$(pgrep -o -f 'sshd.pam.*listener' || pgrep -o sshd)
"
sleep 1

echo "legacy test sshd 已启动: 127.0.0.1:2224  user=dev  password=berth-legacy"
echo "算法: KexAlgorithms=$KEX HostKeyAlgorithms=$HKA Ciphers=aes128-ctr MACs=hmac-sha2-256"
echo "验证: ssh -o KexAlgorithms=$KEX -p 2224 dev@127.0.0.1"
