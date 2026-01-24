# FMMA(FPGA Market Maker Accelerator)
This project aims to design and implement a low-latency market making system using a DE1-SoC FPGA board as the primary engine. The FPGA will execute core components of a market making algorithm while the HPS handles network communication. Communication between the HPS and FPGA will be achieved through memory-mapped I/O using AXI bridges and on-chip RAM, allowing market data to be written directly into FPGA-accessible memory for processing.

The motivation for this project is to explore hardware acceleration techniques commonly used in high-frequency trading (HFT) systems, where latency and parallel computation provide significant advantages over CPU-only implementations. Over the course of two semesters, this project aims to create a prototype capable of receiving real-time market data, processing it on the FPGA, and returning trading decisions to a Linux-based application for execution in a paper-trading environment.

## 1. Project Overview
**Dataflow:**  
WebSocket (Coinbase) → HPS/Linux parser (C) → `mmap()` write → Shared On-Chip RAM (Qsys) → FPGA reader → output (UART/LED/7-seg or writeback RAM)

## 2. Repository Structure
docs/ -> Project description, test results, etc.

## 3. Requirements
### Hardware
- DE1-SoC board (Cyclone V SoC)
- microSD card (for Linux image)
- Ethernet connection

### Software
- Quartus Prime 
- ModelSim/Questa
- PuTTY (serial + SSH) and PSCP/SCP
- On HPS Linux:
  - `build-essential` (gcc/make)
  - network access (DNS + default route)
  
## 4. HPS/Linux Bring-up
1) Boot embedded Linux from microSD 

2) Serial console via PuTTY:
- COM port: (your COM)
- Baud: **115200**

3) Configure DNS:
- sudo nano /etc/resolv.conf
- nameserver 8.8.8.8
- nameserver 8.8.4.4

4) Set default gateway:
- sudo ip route add default via <your_gateway> dev eth0

5) Verify network:
- ping -c 3 8.8.8.8
- ping -c 3 google.com

## 5. Build & Program FPGA

## 6. Shared Memory Protocol

## 7. Build & Run HPS Software
### Install build tools
- sudo apt-get update
- sudo apt-get install build-essential

## 8. Demo