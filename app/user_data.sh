#!/bin/bash
yum update -y
yum install -y python3 python3-pip

mkdir -p /app

cat > /app/app.py << 'EOF'
from flask import Flask, jsonify
import socket

app = Flask(__name__)

@app.route("/")
def home():
    return jsonify({
        "message": "Hello from the HA Web App!",
        "server": socket.gethostname(),
        "status": "healthy"
    })

@app.route("/health")
def health():
    return jsonify({"status": "ok"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

pip3 install flask gunicorn

# Run on port 8080 (no root needed)
cd /app
nohup gunicorn -w 2 -b 0.0.0.0:8080 app:app > /var/log/app.log 2>&1 &

# Start on reboot
echo "@reboot root cd /app && gunicorn -w 2 -b 0.0.0.0:8080 app:app >> /var/log/app.log 2>&1" >> /etc/crontab