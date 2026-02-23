import sys
import subprocess
import os
import requests
import time
import json
import logging

# Configure logging to file to avoid corrupting MCP stdio
logging.basicConfig(
    filename='mcp_server.log',
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    logging.error("mcp package not found. Please install it with 'pip install mcp'")
    # We can't exit here gracefully without mcp, but let's assume it's there.
    # If not, the script will crash, which is expected.
    pass

mcp = FastMCP("FlutterDriver")

FLUTTER_PROCESS = None
DRIVER_PORT = 8888
DRIVER_URL = f"http://127.0.0.1:{DRIVER_PORT}"

@mcp.tool()
def start_app():
    """Starts the Flutter application in driver mode. MUST be called first."""
    global FLUTTER_PROCESS
    if FLUTTER_PROCESS:
        return "App already running"
    
    # Check if driver is already running on port 8888
    try:
        requests.post(DRIVER_URL, json={"command": "ping"}, timeout=1)
        logging.info("Driver already running on port 8888")
        return "App already running (external)"
    except:
        pass # Not running, proceed to launch
    
    logging.info("Starting Flutter Drive...")
    
    log_file = open("flutter_driver.log", "w")
    
    # Run flutter drive
    cmd = [
        "flutter", "drive",
        "--target=test_driver/app.dart",
        "--driver=test_driver/interactive_driver.dart",
        "-d", "windows"
    ]
    
    FLUTTER_PROCESS = subprocess.Popen(
        cmd,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        cwd=os.getcwd(),
        shell=True
    )
    
    # Wait for server to be up
    start_time = time.time()
    # First build might take a long time (e.g. 5 minutes)
    while time.time() - start_time < 300:
        try:
            requests.post(DRIVER_URL, json={"command": "ping"}, timeout=1)
            return "App started and connected"
        except requests.exceptions.ConnectionError:
            time.sleep(1)
        except Exception as e:
            logging.error(f"Error checking driver: {e}")
            time.sleep(1)
            
    return "App started but driver server not responding yet. Check flutter_driver.log."

@mcp.tool()
def stop_app():
    """Stops the Flutter application."""
    global FLUTTER_PROCESS
    if FLUTTER_PROCESS:
        FLUTTER_PROCESS.terminate()
        FLUTTER_PROCESS = None
        return "App stopped"
    return "App not running"

@mcp.tool()
def tap(key: str = None, text: str = None, tooltip: str = None):
    """Tap on a widget found by key, text, or tooltip."""
    return _send_command("tap", {"key": key, "text": text, "tooltip": tooltip, "type": _infer_type(key, text, tooltip)})

@mcp.tool()
def enter_text(text: str):
    """Enter text into the currently focused widget."""
    return _send_command("enter_text", {"text": text})

@mcp.tool()
def get_text(key: str = None, tooltip: str = None):
    """Get text content of a widget."""
    return _send_command("get_text", {"key": key, "tooltip": tooltip, "type": _infer_type(key, None, tooltip)})

@mcp.tool()
def wait_for(key: str = None, text: str = None, tooltip: str = None):
    """Wait for a widget to appear on screen."""
    return _send_command("wait_for", {"key": key, "text": text, "tooltip": tooltip, "type": _infer_type(key, text, tooltip)})

@mcp.tool()
def screenshot():
    """Take a screenshot of the current screen. Returns base64 string."""
    return _send_command("screenshot", {})

@mcp.tool()
def get_render_tree():
    """Get the render tree dump of the app."""
    return _send_command("get_render_tree", {})

@mcp.tool()
def scroll(key: str = None, text: str = None, dx: float = 0.0, dy: float = 0.0, duration_ms: int = 300):
    """Scroll a widget by dx, dy."""
    return _send_command("scroll", {
        "key": key, "text": text, 
        "type": _infer_type(key, text, None),
        "dx": dx, "dy": dy, "durationMs": duration_ms
    })

def _infer_type(key, text, tooltip):
    if key: return "value_key"
    if tooltip: return "tooltip"
    if text: return "text"
    return None

def _send_command(command, args):
    logging.info(f"Sending command: {command} with args: {args}")
    try:
        response = requests.post(
            DRIVER_URL,
            json={"command": command, "args": args},
            timeout=60
        )
        if response.status_code == 200:
            res = response.json()
            if res.get("status") == "success":
                return res.get("result")
            else:
                return f"Driver Error: {res.get('message')}"
        else:
            return f"HTTP Error {response.status_code}: {response.text}"
    except Exception as e:
        logging.error(f"Connection error: {e}")
        return f"Connection error: {e}. Is the app started?"

if __name__ == "__main__":
    mcp.run()
