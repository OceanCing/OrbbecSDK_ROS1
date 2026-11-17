#!/usr/bin/env python3
import argparse
import os
import signal
import socket
import subprocess
import threading
import time

import numpy as np
import rosnode
import rospy
from sensor_msgs.msg import Image

os.environ["ROS_MASTER_URI"] = "http://127.0.0.1:11411"
os.environ["ROS_HOSTNAME"] = "127.0.0.1"
parser = argparse.ArgumentParser(description="Short hardware test: CPU Mesa depth stream and stop/restart")
parser.add_argument("--prefix", default="/opt/orbbec-mesa-cpu/25.2.8")
parser.add_argument("--width", type=int, default=512)
parser.add_argument("--height", type=int, default=512)
parser.add_argument("--log", default="/tmp/orbbec-cpu-mesa-validation.log")
args = parser.parse_args()
log_path = args.log
log = open(log_path, "w")
with socket.socket() as port_check:
    port_check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    port_check.bind(("127.0.0.1", 11411))
launch = subprocess.Popen(
    ["roslaunch", "orbbec_camera", "femto_bolt.launch", "use_cpu_mesa:=true",
     "cpu_mesa_prefix:=" + args.prefix, "camera_name:=femto_cpu_check", "log_level:=warn",
     "depth_width:=" + str(args.width), "depth_height:=" + str(args.height), "depth_fps:=30",
     "ir_width:=" + str(args.width), "ir_height:=" + str(args.height), "ir_fps:=30"],
    stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
)
try:
    # Refuse to share an existing master: this check owns its launch process group.
    rospy.init_node("orbbec_cpu_stability_check", anonymous=True, disable_signals=True)
    for cycle in range(2):
        done = threading.Event()
        samples = []

        def received(msg):
            values = np.frombuffer(msg.data, dtype=">u2" if msg.is_bigendian else "<u2")
            if msg.encoding == "16UC1" and (msg.width, msg.height) == (args.width, args.height) and np.count_nonzero(values):
                samples.append(msg.header.stamp.to_sec())
                if len(samples) >= 40:
                    done.set()

        subscriber = rospy.Subscriber("/femto_cpu_check/depth/image_raw", Image, received, queue_size=1)
        if not done.wait(35):
            raise RuntimeError(f"Timed out in cycle {cycle}: {len(samples)} valid depth messages")
        print(f"Cycle {cycle + 1}: {len(samples)} valid depth messages, {(len(samples)-1)/(samples[-1]-samples[0]):.2f} fps", flush=True)
        subscriber.unregister()
        time.sleep(2)
        if not rosnode.rosnode_ping("/femto_cpu_check/camera", max_count=1, verbose=False):
            raise RuntimeError("Camera node exited after subscriber disconnected")
        print(f"Cycle {cycle + 1}: node remains alive after unsubscribe", flush=True)
finally:
    rospy.signal_shutdown("check finished")
    if launch.poll() is None:
        os.killpg(launch.pid, signal.SIGINT)
    try:
        launch.wait(timeout=12)
    except subprocess.TimeoutExpired:
        os.killpg(launch.pid, signal.SIGTERM)
        launch.wait(timeout=5)
    log.close()
    print("ROS test log:", log_path, flush=True)
