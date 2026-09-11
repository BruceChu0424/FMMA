> **Archived — ECE 3710, autumn 2025.** This is the README from the archive
> the CPU came from. It is kept for provenance and because its account of
> the HPS/Linux bring-up is still the best narrative of how that was first
> done. It is **not** a description of the current system.
>
> Two things in it are wrong for this design: the HPS-to-FPGA bridge base is
> `0xFF200000` (the **lightweight** bridge), not `0xC8000000`; and the
> closing statement that the FPGA could not read what the HPS wrote is no
> longer true. See [`../07-shared-memory-protocol.md`](../07-shared-memory-protocol.md)
> and [`../11-board-bringup.md`](../11-board-bringup.md).

---

This is the project done by group 1011 in ECE 3710. The group members for this project are Kaleb, Carson, Bobby, and Henry. This project is a High-Frequency Stock Trader. 
Our archive contains four folders. This current folder with the readme and the final report.
We have a code folder containing all the code we wrote for our CPU, along with our final algorithm in machine code. I also added a few of our FSMs from
labs 2 and 3. We have a software folder that contains all our code for our HPS to FPGA communication, our code that talks to our trading software, and our assembler. 
Our final folder is for testbenches. We don't have a large number of testbenches, as we have updated them incrementally. However, we have added the ones that we do have. 
We also added our testbench results for lab 4, so that you could see how we viewed our results.  We appreciate the time and effort that everyone put into this course, 
and we hope you enjoy our project!

STEPS FOR HPS AND EMBEDDED LINUX INTEGRATION:

The HPS integration was a particularly challenging section of this project. As it was beyond the scope of this class, 
there was a lot to learn. It required knowledge in digital design, networking, Linux, C programming, and a lot of research. 
First, we needed to get embedded Linux installed onto the HPS. We followed the steps listed on Cornell’s ECE website [1]. We were able to load this onto a
microSD card and insert it in the DE1-SoC board. Once this was done, we needed a way to communicate. PuTTY was the software of choice for an SSH connection 
to the embedded Linux. It required a serial connection under the appropriate COM port and a serial of 115200.

Now that we have a way to communicate with Linux, we must set it up for internet connection as this does not come by default. First, we need to 
add the Google DNS IP to our DNS list. This is done by the nano /etc/resolv.conf command. Here, we add nameserver 8.8.8.8 and nameserver 8.8.4.4. 
Next, we need to set the default gateway for Linux. This requires use of the following command: ip route add default via <your gateway>(eg:192.168.1.1) dev eth0 [2]. 
The gateway is the IP address of your router (this cannot be done on school grounds without an IP/Mac exception, we had to do at home). 
The final networking step is to set up file sharing between your personal computer and linux (this can be avoided if you are smart and know how to use git). 
This requires the installation of the PSCP (PuTTY Secure Copy) software on your machine [3]. Once this is done, and assuming your Linux and PC are on the same network,
you can use the command “pscp pscp-test.txt paul@192.168.1.23:/home/paul” where you choose what file to move over and the address of your Linux (was root@192.168.1.123 for us).

Now we need to get the embedded Linux on the HPS talking with our FPGA. This part required a LOT of research as there were no fully documented 
cases for this type of setup. We chose to use C language for its fast mmap() function. With mmap, we can write directly to a BRAM address on our FPGA. 
You first must install C on the Linux machine with the command “apt-get update”, followed by “apt-get install build-essential". Next, we need to build a physical link 
between the HPS and our system. This requires the use of the Platform Designer software that is built into Linux. From here, we can instantiate
an On-Chip RAM module (this eventually replaced our initial BRAM), as well as the Arria V/Cyclone V Hard Processor System module.
Once these have been added, we followed the steps of a YouTube video to get the general understanding of how the connection works [4]. Personally, the
compilation of the .qsys file from Platform Designer required the installation of a Linux subsystem on my windows machine. Following the steps from Intel’s website, 
we can get this installed [5]. Now that we’ve got a dual-port single clock BRAM module created, we can export the s2 port for the BRAM to be used in our verilog, 
with s1 being connected to our HPS over an AXI Master-Slave connection. It is important to note that addresses chosen in Platform Designer for your BRAM are not the
same address names you will write to on the Linux system. For the AXI Master bridge, the Linux mmap base address will be 0xC8000000 [6]. If you decide to use the
slower Lightweight AXI Master, the address is 0xFF200000. Our C code shows how to properly use these addresses.

Finally, with everything configured for connection, we can write the C code that pulls market data from the internet 
(we chose the Coinbase WebSocket as it gave us the ability to pull data once every 200ms) and input it directly into the FPGA for 
calculation. Ideally, this is done with an ethernet stack decoding messages directly sent from a stock exchange; however, we do not have access to any 
stock exchange data cables in SLC. This was the lowest latency solution we could use given our location. To execute the trades, we planned to use the 
Alpaca trading API as it allows us to create a “paper trading” account and test our infrastructure. We were unable to get our FPGA to properly read the 
information sent from the HPS and have it calculated properly due to time constraints. If we had more time, we would be able to get our data written to 
BRAM appropriately, as well as have a program written to correctly read the information provided by the HPS. If we were able to sort that out, the Alpaca 
integration would be the next step, and we would be on our way to implementing a full-stack HFT Market Making Scheme with profit.
