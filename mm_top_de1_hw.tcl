# -----------------------------------------------------------------------------
# mm_top_de1_hw.tcl
#
# Platform Designer component for mm_top_de1. Put this file, mm_top_de1.v and
# the rtl/ folder in your Quartus project directory; the component then shows
# up in the IP Catalog under "Market Making > Market maker core".
# -----------------------------------------------------------------------------
package require -exact qsys 16.1

set_module_property NAME                         mm_top_de1
set_module_property DISPLAY_NAME                 "Market maker core"
set_module_property DESCRIPTION                  "Per-symbol order books and quoting with an AXI4-Lite control plane"
set_module_property VERSION                      1.0
set_module_property GROUP                        "Market Making"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE                     true

# ---- Files ------------------------------------------------------------------
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL mm_top_de1
add_fileset_file mm_top_de1.v   VERILOG PATH mm_top_de1.v         TOP_LEVEL_FILE
add_fileset_file mm_top.v       VERILOG PATH rtl/mm_top.v
add_fileset_file axi_ctrl.v     VERILOG PATH rtl/axi_ctrl.v
add_fileset_file mm_core.v      VERILOG PATH rtl/mm_core.v
add_fileset_file book_bank.v    VERILOG PATH rtl/book_bank.v
add_fileset_file quote_engine.v VERILOG PATH rtl/quote_engine.v

# ---- Clock and reset ----------------------------------------------------------
add_interface clock clock end
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges BOTH
add_interface_port reset rst reset Input 1

# ---- AXI4-Lite slave (connect to hps_0.h2f_lw_axi_master) ---------------------
add_interface s_axi axi4lite end
set_interface_property s_axi associatedClock clock
set_interface_property s_axi associatedReset reset
add_interface_port s_axi s_axi_awaddr  awaddr  Input  18
add_interface_port s_axi s_axi_awprot  awprot  Input  3
add_interface_port s_axi s_axi_awvalid awvalid Input  1
add_interface_port s_axi s_axi_awready awready Output 1
add_interface_port s_axi s_axi_wdata   wdata   Input  32
add_interface_port s_axi s_axi_wstrb   wstrb   Input  4
add_interface_port s_axi s_axi_wvalid  wvalid  Input  1
add_interface_port s_axi s_axi_wready  wready  Output 1
add_interface_port s_axi s_axi_bresp   bresp   Output 2
add_interface_port s_axi s_axi_bvalid  bvalid  Output 1
add_interface_port s_axi s_axi_bready  bready  Input  1
add_interface_port s_axi s_axi_araddr  araddr  Input  18
add_interface_port s_axi s_axi_arprot  arprot  Input  3
add_interface_port s_axi s_axi_arvalid arvalid Input  1
add_interface_port s_axi s_axi_arready arready Output 1
add_interface_port s_axi s_axi_rdata   rdata   Output 32
add_interface_port s_axi s_axi_rresp   rresp   Output 2
add_interface_port s_axi s_axi_rvalid  rvalid  Output 1
add_interface_port s_axi s_axi_rready  rready  Input  1

# ---- Conduits, exported to the top level --------------------------------------
add_interface feed conduit end
set_interface_property feed associatedClock clock
add_interface_port feed upd_valid upd_valid Input 1
add_interface_port feed upd_sym   upd_sym   Input 2
add_interface_port feed upd_side  upd_side  Input 1
add_interface_port feed upd_idx   upd_idx   Input 10
add_interface_port feed upd_delta upd_delta Input 32

add_interface inventory conduit end
set_interface_property inventory associatedClock clock
add_interface_port inventory position   position   Input 128
add_interface_port inventory pos_update pos_update Input 4

add_interface quotes conduit end
set_interface_property quotes associatedClock clock
add_interface_port quotes q_valid  q_valid  Output 4
add_interface_port quotes q_bid_en q_bid_en Output 4
add_interface_port quotes q_ask_en q_ask_en Output 4
add_interface_port quotes q_bid    q_bid    Output 40
add_interface_port quotes q_ask    q_ask    Output 40
