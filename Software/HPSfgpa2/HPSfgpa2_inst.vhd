	component HPSfgpa2 is
		port (
			clk_clk                         : in    std_logic                     := 'X';             -- clk
			memory_mem_a                    : out   std_logic_vector(12 downto 0);                    -- mem_a
			memory_mem_ba                   : out   std_logic_vector(2 downto 0);                     -- mem_ba
			memory_mem_ck                   : out   std_logic;                                        -- mem_ck
			memory_mem_ck_n                 : out   std_logic;                                        -- mem_ck_n
			memory_mem_cke                  : out   std_logic;                                        -- mem_cke
			memory_mem_cs_n                 : out   std_logic;                                        -- mem_cs_n
			memory_mem_ras_n                : out   std_logic;                                        -- mem_ras_n
			memory_mem_cas_n                : out   std_logic;                                        -- mem_cas_n
			memory_mem_we_n                 : out   std_logic;                                        -- mem_we_n
			memory_mem_reset_n              : out   std_logic;                                        -- mem_reset_n
			memory_mem_dq                   : inout std_logic_vector(7 downto 0)  := (others => 'X'); -- mem_dq
			memory_mem_dqs                  : inout std_logic                     := 'X';             -- mem_dqs
			memory_mem_dqs_n                : inout std_logic                     := 'X';             -- mem_dqs_n
			memory_mem_odt                  : out   std_logic;                                        -- mem_odt
			memory_mem_dm                   : out   std_logic;                                        -- mem_dm
			memory_oct_rzqin                : in    std_logic                     := 'X';             -- oct_rzqin
			hps_0_h2f_mpu_events_eventi     : in    std_logic                     := 'X';             -- eventi
			hps_0_h2f_mpu_events_evento     : out   std_logic;                                        -- evento
			hps_0_h2f_mpu_events_standbywfe : out   std_logic_vector(1 downto 0);                     -- standbywfe
			hps_0_h2f_mpu_events_standbywfi : out   std_logic_vector(1 downto 0);                     -- standbywfi
			fpga_bram_s2_address            : in    std_logic_vector(9 downto 0)  := (others => 'X'); -- address
			fpga_bram_s2_chipselect         : in    std_logic                     := 'X';             -- chipselect
			fpga_bram_s2_clken              : in    std_logic                     := 'X';             -- clken
			fpga_bram_s2_write              : in    std_logic                     := 'X';             -- write
			fpga_bram_s2_readdata           : out   std_logic_vector(31 downto 0);                    -- readdata
			fpga_bram_s2_writedata          : in    std_logic_vector(31 downto 0) := (others => 'X'); -- writedata
			fpga_bram_s2_byteenable         : in    std_logic_vector(3 downto 0)  := (others => 'X')  -- byteenable
		);
	end component HPSfgpa2;

	u0 : component HPSfgpa2
		port map (
			clk_clk                         => CONNECTED_TO_clk_clk,                         --                  clk.clk
			memory_mem_a                    => CONNECTED_TO_memory_mem_a,                    --               memory.mem_a
			memory_mem_ba                   => CONNECTED_TO_memory_mem_ba,                   --                     .mem_ba
			memory_mem_ck                   => CONNECTED_TO_memory_mem_ck,                   --                     .mem_ck
			memory_mem_ck_n                 => CONNECTED_TO_memory_mem_ck_n,                 --                     .mem_ck_n
			memory_mem_cke                  => CONNECTED_TO_memory_mem_cke,                  --                     .mem_cke
			memory_mem_cs_n                 => CONNECTED_TO_memory_mem_cs_n,                 --                     .mem_cs_n
			memory_mem_ras_n                => CONNECTED_TO_memory_mem_ras_n,                --                     .mem_ras_n
			memory_mem_cas_n                => CONNECTED_TO_memory_mem_cas_n,                --                     .mem_cas_n
			memory_mem_we_n                 => CONNECTED_TO_memory_mem_we_n,                 --                     .mem_we_n
			memory_mem_reset_n              => CONNECTED_TO_memory_mem_reset_n,              --                     .mem_reset_n
			memory_mem_dq                   => CONNECTED_TO_memory_mem_dq,                   --                     .mem_dq
			memory_mem_dqs                  => CONNECTED_TO_memory_mem_dqs,                  --                     .mem_dqs
			memory_mem_dqs_n                => CONNECTED_TO_memory_mem_dqs_n,                --                     .mem_dqs_n
			memory_mem_odt                  => CONNECTED_TO_memory_mem_odt,                  --                     .mem_odt
			memory_mem_dm                   => CONNECTED_TO_memory_mem_dm,                   --                     .mem_dm
			memory_oct_rzqin                => CONNECTED_TO_memory_oct_rzqin,                --                     .oct_rzqin
			hps_0_h2f_mpu_events_eventi     => CONNECTED_TO_hps_0_h2f_mpu_events_eventi,     -- hps_0_h2f_mpu_events.eventi
			hps_0_h2f_mpu_events_evento     => CONNECTED_TO_hps_0_h2f_mpu_events_evento,     --                     .evento
			hps_0_h2f_mpu_events_standbywfe => CONNECTED_TO_hps_0_h2f_mpu_events_standbywfe, --                     .standbywfe
			hps_0_h2f_mpu_events_standbywfi => CONNECTED_TO_hps_0_h2f_mpu_events_standbywfi, --                     .standbywfi
			fpga_bram_s2_address            => CONNECTED_TO_fpga_bram_s2_address,            --         fpga_bram_s2.address
			fpga_bram_s2_chipselect         => CONNECTED_TO_fpga_bram_s2_chipselect,         --                     .chipselect
			fpga_bram_s2_clken              => CONNECTED_TO_fpga_bram_s2_clken,              --                     .clken
			fpga_bram_s2_write              => CONNECTED_TO_fpga_bram_s2_write,              --                     .write
			fpga_bram_s2_readdata           => CONNECTED_TO_fpga_bram_s2_readdata,           --                     .readdata
			fpga_bram_s2_writedata          => CONNECTED_TO_fpga_bram_s2_writedata,          --                     .writedata
			fpga_bram_s2_byteenable         => CONNECTED_TO_fpga_bram_s2_byteenable          --                     .byteenable
		);

