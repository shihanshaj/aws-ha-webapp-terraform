from flask import Flask, jsonify
import socket
import os

app = Flask(__name__)

@app.route("/")
def home():
    return jsonify({
        "message": "Hello from the HA Web App!",
        "server": socket.gethostname(),  # shows WHICH server answered
        "status": "healthy"
    })

@app.route("/health")
def health():
    return jsonify({"status": "ok"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)