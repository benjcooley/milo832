-------------------------------------------------------------------------------
-- system_bus_pkg.vhd
-- System Bus Package: Types, Constants, and Utilities
--
-- Defines the bus protocol used by m65832 CPU, Milo832 GPU, and peripherals.
-- Supports multi-master arbitration with burst transfers.
--
-- This file is shared between milo832 and m65832 projects.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package system_bus_pkg is

    ---------------------------------------------------------------------------
    -- Bus Configuration Constants
    ---------------------------------------------------------------------------
    constant BUS_ADDR_WIDTH : integer := 32;
    constant BUS_DATA_WIDTH : integer := 64;  -- 64-bit for DDR efficiency
    constant BUS_STRB_WIDTH : integer := BUS_DATA_WIDTH / 8;
    
    constant BUS_MASTERS    : integer := 6;   -- CPU, GPU, DMA, Audio, Video, Debug
    constant BUS_SLAVES     : integer := 12;  -- See address map below
    
    ---------------------------------------------------------------------------
    -- Address Map Constants
    ---------------------------------------------------------------------------
    -- Region base addresses [31:28]
    constant REGION_DDR       : std_logic_vector(3 downto 0) := x"0";  -- DDR/ROM
    constant REGION_PERIPH    : std_logic_vector(3 downto 0) := x"1";  -- Peripherals
    constant REGION_EXTERNAL  : std_logic_vector(3 downto 0) := x"2";  -- Expansion
    
    -- Peripheral offsets [27:12] (4KB pages)
    constant PERIPH_GPU       : std_logic_vector(15 downto 0) := x"0000";
    constant PERIPH_DMA       : std_logic_vector(15 downto 0) := x"0001";
    constant PERIPH_AUDIO     : std_logic_vector(15 downto 0) := x"0002";
    constant PERIPH_VIDEO     : std_logic_vector(15 downto 0) := x"0003";
    constant PERIPH_TIMER     : std_logic_vector(15 downto 0) := x"0004";
    constant PERIPH_IRQ       : std_logic_vector(15 downto 0) := x"0005";
    constant PERIPH_UART      : std_logic_vector(15 downto 0) := x"0006";
    constant PERIPH_SPI       : std_logic_vector(15 downto 0) := x"0007";
    constant PERIPH_I2C       : std_logic_vector(15 downto 0) := x"0008";
    constant PERIPH_GPIO      : std_logic_vector(15 downto 0) := x"0009";
    constant PERIPH_SD        : std_logic_vector(15 downto 0) := x"000A";
    
    -- DDR regions
    constant DDR_BOOT_ROM_BASE  : std_logic_vector(31 downto 0) := x"00000000";
    constant DDR_BOOT_ROM_SIZE  : integer := 65536;  -- 64KB
    constant DDR_CPU_BASE       : std_logic_vector(31 downto 0) := x"00010000";
    constant DDR_SHARED_BASE    : std_logic_vector(31 downto 0) := x"00200000";
    
    ---------------------------------------------------------------------------
    -- Master Priority (0 = highest)
    ---------------------------------------------------------------------------
    constant MASTER_CPU     : integer := 0;
    constant MASTER_GPU     : integer := 1;
    constant MASTER_DMA     : integer := 2;
    constant MASTER_AUDIO   : integer := 3;
    constant MASTER_VIDEO   : integer := 4;
    constant MASTER_DEBUG   : integer := 5;
    
    -- Priority levels for two-level arbitration
    type priority_group_t is (PRIO_REALTIME, PRIO_HIGH, PRIO_NORMAL, PRIO_LOW);
    
    ---------------------------------------------------------------------------
    -- Transfer Size Encoding
    ---------------------------------------------------------------------------
    constant SIZE_BYTE   : std_logic_vector(2 downto 0) := "000";  -- 1 byte
    constant SIZE_HALF   : std_logic_vector(2 downto 0) := "001";  -- 2 bytes
    constant SIZE_WORD   : std_logic_vector(2 downto 0) := "010";  -- 4 bytes
    constant SIZE_DWORD  : std_logic_vector(2 downto 0) := "011";  -- 8 bytes
    
    ---------------------------------------------------------------------------
    -- Protection Level Encoding
    ---------------------------------------------------------------------------
    constant PROT_USER       : std_logic_vector(2 downto 0) := "000";
    constant PROT_SUPERVISOR : std_logic_vector(2 downto 0) := "001";
    constant PROT_SECURE     : std_logic_vector(2 downto 0) := "010";
    
    ---------------------------------------------------------------------------
    -- Bus Request Record (Master -> Arbiter)
    ---------------------------------------------------------------------------
    type bus_master_req_t is record
        valid    : std_logic;                              -- Request valid
        write    : std_logic;                              -- 1=write, 0=read
        addr     : std_logic_vector(31 downto 0);          -- Address
        wdata    : std_logic_vector(63 downto 0);          -- Write data
        wstrb    : std_logic_vector(7 downto 0);           -- Byte enables
        burst    : std_logic_vector(7 downto 0);           -- Burst length-1 (0=single)
        size     : std_logic_vector(2 downto 0);           -- Transfer size
        lock     : std_logic;                              -- Atomic access
        prot     : std_logic_vector(2 downto 0);           -- Protection level
    end record bus_master_req_t;
    
    constant BUS_MASTER_REQ_INIT : bus_master_req_t := (
        valid => '0',
        write => '0',
        addr  => (others => '0'),
        wdata => (others => '0'),
        wstrb => (others => '0'),
        burst => (others => '0'),
        size  => SIZE_WORD,
        lock  => '0',
        prot  => PROT_USER
    );
    
    ---------------------------------------------------------------------------
    -- Bus Response Record (Arbiter -> Master)
    ---------------------------------------------------------------------------
    type bus_master_resp_t is record
        ready    : std_logic;                              -- Request accepted
        rvalid   : std_logic;                              -- Read data valid
        rdata    : std_logic_vector(63 downto 0);          -- Read data
        error    : std_logic;                              -- Bus/decode error
        rlast    : std_logic;                              -- Last beat of burst
    end record bus_master_resp_t;
    
    constant BUS_MASTER_RESP_INIT : bus_master_resp_t := (
        ready  => '0',
        rvalid => '0',
        rdata  => (others => '0'),
        error  => '0',
        rlast  => '0'
    );
    
    ---------------------------------------------------------------------------
    -- Slave Request Record (Interconnect -> Slave)
    ---------------------------------------------------------------------------
    type bus_slave_req_t is record
        sel      : std_logic;                              -- Slave selected
        write    : std_logic;                              -- 1=write, 0=read
        addr     : std_logic_vector(31 downto 0);          -- Address (full)
        wdata    : std_logic_vector(63 downto 0);          -- Write data
        wstrb    : std_logic_vector(7 downto 0);           -- Byte enables
        burst    : std_logic_vector(7 downto 0);           -- Burst length-1
    end record bus_slave_req_t;
    
    constant BUS_SLAVE_REQ_INIT : bus_slave_req_t := (
        sel   => '0',
        write => '0',
        addr  => (others => '0'),
        wdata => (others => '0'),
        wstrb => (others => '0'),
        burst => (others => '0')
    );
    
    ---------------------------------------------------------------------------
    -- Slave Response Record (Slave -> Interconnect)
    ---------------------------------------------------------------------------
    type bus_slave_resp_t is record
        ready    : std_logic;                              -- Slave ready
        rvalid   : std_logic;                              -- Read data valid
        rdata    : std_logic_vector(63 downto 0);          -- Read data
        error    : std_logic;                              -- Slave error
        rlast    : std_logic;                              -- Last beat
    end record bus_slave_resp_t;
    
    constant BUS_SLAVE_RESP_INIT : bus_slave_resp_t := (
        ready  => '1',  -- Default ready (no wait states)
        rvalid => '0',
        rdata  => (others => '0'),
        error  => '0',
        rlast  => '1'
    );
    
    ---------------------------------------------------------------------------
    -- Array Types for Multi-Master/Slave
    ---------------------------------------------------------------------------
    type master_req_array_t is array (natural range <>) of bus_master_req_t;
    type master_resp_array_t is array (natural range <>) of bus_master_resp_t;
    type slave_req_array_t is array (natural range <>) of bus_slave_req_t;
    type slave_resp_array_t is array (natural range <>) of bus_slave_resp_t;
    
    ---------------------------------------------------------------------------
    -- QoS Configuration Record
    ---------------------------------------------------------------------------
    type qos_config_t is record
        priority   : std_logic_vector(3 downto 0);         -- 0=highest
        bandwidth  : std_logic_vector(7 downto 0);         -- Bandwidth limit
        latency    : std_logic_vector(7 downto 0);         -- Max latency cycles
    end record qos_config_t;
    
    constant QOS_DEFAULT : qos_config_t := (
        priority  => x"8",
        bandwidth => x"FF",  -- No limit
        latency   => x"FF"   -- No limit
    );
    
    type qos_array_t is array (natural range <>) of qos_config_t;
    
    ---------------------------------------------------------------------------
    -- Helper Functions
    ---------------------------------------------------------------------------
    
    -- Decode address to slave index
    function addr_to_slave(addr : std_logic_vector(31 downto 0)) return integer;
    
    -- Check if address is cacheable
    function is_cacheable(addr : std_logic_vector(31 downto 0)) return boolean;
    
    -- Generate byte strobe from size and address
    function size_to_strobe(
        size : std_logic_vector(2 downto 0);
        addr : std_logic_vector(2 downto 0)
    ) return std_logic_vector;

end package system_bus_pkg;

package body system_bus_pkg is

    ---------------------------------------------------------------------------
    -- Address Decoder
    ---------------------------------------------------------------------------
    function addr_to_slave(addr : std_logic_vector(31 downto 0)) return integer is
        variable region : std_logic_vector(3 downto 0);
        variable periph : std_logic_vector(15 downto 0);
    begin
        region := addr(31 downto 28);
        periph := addr(27 downto 12);
        
        case region is
            when REGION_DDR =>
                -- Boot ROM or DDR
                if unsigned(addr) < unsigned(DDR_CPU_BASE) then
                    return 0;  -- Boot ROM
                else
                    return 1;  -- DDR Memory
                end if;
                
            when REGION_PERIPH =>
                -- Peripheral decode
                case periph is
                    when PERIPH_GPU   => return 2;
                    when PERIPH_DMA   => return 3;
                    when PERIPH_AUDIO => return 4;
                    when PERIPH_VIDEO => return 5;
                    when PERIPH_TIMER => return 6;
                    when PERIPH_IRQ   => return 7;
                    when PERIPH_UART  => return 8;
                    when PERIPH_SPI   => return 9;
                    when PERIPH_I2C   => return 10;
                    when PERIPH_GPIO  => return 11;
                    when others       => return 0;  -- Default to ROM (will error)
                end case;
                
            when others =>
                return 0;  -- Invalid region
        end case;
    end function;
    
    ---------------------------------------------------------------------------
    -- Cacheability Check
    ---------------------------------------------------------------------------
    function is_cacheable(addr : std_logic_vector(31 downto 0)) return boolean is
    begin
        -- Only DDR region is cacheable
        return addr(31 downto 28) = REGION_DDR;
    end function;
    
    ---------------------------------------------------------------------------
    -- Byte Strobe Generator
    ---------------------------------------------------------------------------
    function size_to_strobe(
        size : std_logic_vector(2 downto 0);
        addr : std_logic_vector(2 downto 0)
    ) return std_logic_vector is
        variable strobe : std_logic_vector(7 downto 0);
        variable offset : integer;
    begin
        offset := to_integer(unsigned(addr));
        strobe := (others => '0');
        
        case size is
            when SIZE_BYTE =>
                strobe(offset) := '1';
            when SIZE_HALF =>
                strobe(offset+1 downto offset) := "11";
            when SIZE_WORD =>
                strobe(offset+3 downto offset) := "1111";
            when SIZE_DWORD =>
                strobe := "11111111";
            when others =>
                strobe := "11111111";
        end case;
        
        return strobe;
    end function;

end package body system_bus_pkg;
