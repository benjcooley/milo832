-------------------------------------------------------------------------------
-- texel_decoder.vhd
-- Texture Format Decoder
-- Converts various texture formats to RGBA8888
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity texel_decoder is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Input
        valid_in        : in  std_logic;
        format          : in  std_logic_vector(3 downto 0);
        raw_data        : in  std_logic_vector(31 downto 0);  -- Raw texel data
        bit_offset      : in  std_logic_vector(4 downto 0);   -- For sub-byte formats
        
        -- Palette interface (for indexed formats)
        pal_rd_en       : out std_logic;
        pal_rd_addr     : out std_logic_vector(7 downto 0);
        pal_rd_data     : in  std_logic_vector(31 downto 0);
        
        -- Output
        valid_out       : out std_logic;
        rgba_out        : out std_logic_vector(31 downto 0)
    );
end entity texel_decoder;

architecture rtl of texel_decoder is

    ---------------------------------------------------------------------------
    -- Format Constants
    ---------------------------------------------------------------------------
    constant FMT_MONO1      : std_logic_vector(3 downto 0) := "0000";
    constant FMT_PAL4       : std_logic_vector(3 downto 0) := "0001";
    constant FMT_PAL8       : std_logic_vector(3 downto 0) := "0010";
    constant FMT_RGBA4444   : std_logic_vector(3 downto 0) := "0011";
    constant FMT_RGB565     : std_logic_vector(3 downto 0) := "0100";
    constant FMT_RGBA5551   : std_logic_vector(3 downto 0) := "0101";
    constant FMT_LA88       : std_logic_vector(3 downto 0) := "0110";
    constant FMT_L8         : std_logic_vector(3 downto 0) := "0111";
    constant FMT_RGBA8888   : std_logic_vector(3 downto 0) := "1000";
    
    ---------------------------------------------------------------------------
    -- Pipeline Registers
    ---------------------------------------------------------------------------
    type state_t is (IDLE, DECODE_DIRECT, PALETTE_LOOKUP, PALETTE_WAIT, OUTPUT);
    signal state : state_t := IDLE;
    
    signal format_lat : std_logic_vector(3 downto 0);
    signal raw_lat : std_logic_vector(31 downto 0);
    signal offset_lat : unsigned(4 downto 0);
    signal decoded_rgba : std_logic_vector(31 downto 0);
    signal palette_idx : std_logic_vector(7 downto 0);
    signal need_palette : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Main Decode Process
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable bit_pos : integer;
        variable mono_bit : std_logic;
        variable pal4_idx : unsigned(3 downto 0);
        variable pal8_idx : unsigned(7 downto 0);
        variable r4, g4, b4, a4 : unsigned(3 downto 0);
        variable r5, g5, b5 : unsigned(4 downto 0);
        variable g6 : unsigned(5 downto 0);
        variable a1 : std_logic;
        variable l8, a8 : unsigned(7 downto 0);
        variable pixel_16 : std_logic_vector(15 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            valid_out <= '0';
            pal_rd_en <= '0';
            rgba_out <= (others => '0');
            
        elsif rising_edge(clk) then
            -- Default
            valid_out <= '0';
            pal_rd_en <= '0';
            
            case state is
                when IDLE =>
                    if valid_in = '1' then
                        format_lat <= format;
                        raw_lat <= raw_data;
                        offset_lat <= unsigned(bit_offset);
                        
                        -- Check if palette lookup needed
                        if format = FMT_MONO1 or format = FMT_PAL4 or format = FMT_PAL8 then
                            need_palette <= '1';
                            state <= PALETTE_LOOKUP;
                        else
                            need_palette <= '0';
                            state <= DECODE_DIRECT;
                        end if;
                    end if;
                
                when DECODE_DIRECT =>
                    case format_lat is
                        when FMT_RGBA4444 =>
                            pixel_16 := raw_lat(15 downto 0);
                            r4 := unsigned(pixel_16(15 downto 12));
                            g4 := unsigned(pixel_16(11 downto 8));
                            b4 := unsigned(pixel_16(7 downto 4));
                            a4 := unsigned(pixel_16(3 downto 0));
                            -- Expand 4-bit to 8-bit
                            decoded_rgba <= std_logic_vector(r4 & r4) &
                                          std_logic_vector(g4 & g4) &
                                          std_logic_vector(b4 & b4) &
                                          std_logic_vector(a4 & a4);
                        
                        when FMT_RGB565 =>
                            pixel_16 := raw_lat(15 downto 0);
                            r5 := unsigned(pixel_16(15 downto 11));
                            g6 := unsigned(pixel_16(10 downto 5));
                            b5 := unsigned(pixel_16(4 downto 0));
                            -- Expand to 8-bit
                            decoded_rgba <= std_logic_vector(r5 & r5(4 downto 2)) &
                                          std_logic_vector(g6 & g6(5 downto 4)) &
                                          std_logic_vector(b5 & b5(4 downto 2)) &
                                          x"FF";
                        
                        when FMT_RGBA5551 =>
                            pixel_16 := raw_lat(15 downto 0);
                            r5 := unsigned(pixel_16(15 downto 11));
                            g5 := unsigned(pixel_16(10 downto 6));
                            b5 := unsigned(pixel_16(5 downto 1));
                            a1 := pixel_16(0);
                            decoded_rgba <= std_logic_vector(r5 & r5(4 downto 2)) &
                                          std_logic_vector(g5 & g5(4 downto 2)) &
                                          std_logic_vector(b5 & b5(4 downto 2)) &
                                          (a1 & a1 & a1 & a1 & a1 & a1 & a1 & a1);
                        
                        when FMT_LA88 =>
                            l8 := unsigned(raw_lat(15 downto 8));
                            a8 := unsigned(raw_lat(7 downto 0));
                            decoded_rgba <= std_logic_vector(l8) &
                                          std_logic_vector(l8) &
                                          std_logic_vector(l8) &
                                          std_logic_vector(a8);
                        
                        when FMT_L8 =>
                            l8 := unsigned(raw_lat(7 downto 0));
                            decoded_rgba <= std_logic_vector(l8) &
                                          std_logic_vector(l8) &
                                          std_logic_vector(l8) &
                                          x"FF";
                        
                        when FMT_RGBA8888 =>
                            decoded_rgba <= raw_lat;
                        
                        when others =>
                            decoded_rgba <= raw_lat;
                    end case;
                    
                    state <= OUTPUT;
                
                when PALETTE_LOOKUP =>
                    -- Extract palette index based on format
                    case format_lat is
                        when FMT_MONO1 =>
                            bit_pos := to_integer(offset_lat);
                            mono_bit := raw_lat(bit_pos);
                            if mono_bit = '1' then
                                palette_idx <= x"01";
                            else
                                palette_idx <= x"00";
                            end if;
                        
                        when FMT_PAL4 =>
                            bit_pos := to_integer(offset_lat(3 downto 0)) * 4;
                            pal4_idx := unsigned(raw_lat(bit_pos+3 downto bit_pos));
                            palette_idx <= "0000" & std_logic_vector(pal4_idx);
                        
                        when FMT_PAL8 =>
                            pal8_idx := unsigned(raw_lat(7 downto 0));
                            palette_idx <= std_logic_vector(pal8_idx);
                        
                        when others =>
                            palette_idx <= x"00";
                    end case;
                    
                    pal_rd_en <= '1';
                    pal_rd_addr <= palette_idx;
                    state <= PALETTE_WAIT;
                
                when PALETTE_WAIT =>
                    -- Wait one cycle for palette SRAM read
                    state <= OUTPUT;
                    decoded_rgba <= pal_rd_data;
                
                when OUTPUT =>
                    valid_out <= '1';
                    rgba_out <= decoded_rgba;
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
