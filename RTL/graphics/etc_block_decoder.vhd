-------------------------------------------------------------------------------
-- etc_block_decoder.vhd
-- ETC1/ETC2 Block Decoder - Decodes entire 4x4 block in parallel
-- Outputs all 16 texels simultaneously for efficient texture unit integration
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity etc_block_decoder is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Input: compressed block data
        valid_in        : in  std_logic;
        ready_out       : out std_logic;
        format          : in  std_logic_vector(1 downto 0);  -- 00=ETC1, 01=ETC2_RGB, 10=ETC2_RGBA
        block_rgb       : in  std_logic_vector(63 downto 0);
        block_alpha     : in  std_logic_vector(63 downto 0);   -- ETC2_RGBA only
        
        -- Output: all 16 decoded RGBA texels (4x4 block)
        -- Organized as texel[y][x] = rgba_out((y*4+x+1)*32-1 downto (y*4+x)*32)
        valid_out       : out std_logic;
        rgba_out        : out std_logic_vector(16*32-1 downto 0)  -- 16 texels * 32 bits
    );
end entity etc_block_decoder;

architecture rtl of etc_block_decoder is

    ---------------------------------------------------------------------------
    -- ETC1 Modifier Tables (per Khronos specification)
    -- Indexed by table_codeword (0-7), then by pixel_index (0-3)
    ---------------------------------------------------------------------------
    type modifier_table_t is array (0 to 7, 0 to 3) of integer;
    constant ETC_MODIFIERS : modifier_table_t := (
        (  2,   8,  -2,   -8),
        (  5,  17,  -5,  -17),
        (  9,  29,  -9,  -29),
        ( 13,  42, -13,  -42),
        ( 18,  60, -18,  -60),
        ( 24,  80, -24,  -80),
        ( 33, 106, -33, -106),
        ( 47, 183, -47, -183)
    );
    
    ---------------------------------------------------------------------------
    -- State Machine
    ---------------------------------------------------------------------------
    type state_t is (IDLE, DECODE, OUTPUT);
    signal state : state_t := IDLE;
    
    ---------------------------------------------------------------------------
    -- Latched Inputs
    ---------------------------------------------------------------------------
    signal lat_format : std_logic_vector(1 downto 0);
    signal lat_block_rgb : std_logic_vector(63 downto 0);
    signal lat_block_alpha : std_logic_vector(63 downto 0);
    
    ---------------------------------------------------------------------------
    -- Decoded Block Header
    ---------------------------------------------------------------------------
    signal diff_mode : std_logic;
    signal flip_bit : std_logic;
    signal table_idx0 : integer range 0 to 7;
    signal table_idx1 : integer range 0 to 7;
    
    -- Base colors for subblock 0 and 1 (8-bit RGB)
    signal base_r0, base_g0, base_b0 : integer range 0 to 255;
    signal base_r1, base_g1, base_b1 : integer range 0 to 255;
    
    ---------------------------------------------------------------------------
    -- Output Register
    ---------------------------------------------------------------------------
    signal decoded_texels : std_logic_vector(16*32-1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Helper Functions
    ---------------------------------------------------------------------------
    
    -- Clamp integer to 0-255
    function clamp_255(val : integer) return integer is
    begin
        if val < 0 then return 0;
        elsif val > 255 then return 255;
        else return val;
        end if;
    end function;
    
    -- Expand 4-bit color to 8-bit (replicate upper bits)
    function expand_4to8(val : unsigned(3 downto 0)) return integer is
    begin
        return to_integer(val & val);
    end function;
    
    -- Expand 5-bit color to 8-bit (replicate upper 3 bits)
    function expand_5to8(val : unsigned(4 downto 0)) return integer is
    begin
        return to_integer(val & val(4 downto 2));
    end function;
    
    -- Sign extend 3-bit to integer
    function sign_extend_3(val : std_logic_vector(2 downto 0)) return integer is
        variable sval : signed(3 downto 0);
    begin
        sval := signed(val(2) & val);
        return to_integer(sval);
    end function;

begin

    ready_out <= '1' when state = IDLE else '0';
    
    ---------------------------------------------------------------------------
    -- Main Decode Process
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable r0_5, g0_5, b0_5 : unsigned(4 downto 0);
        variable r1_5, g1_5, b1_5 : integer;
        variable r0_4, g0_4, b0_4 : unsigned(3 downto 0);
        variable r1_4, g1_4, b1_4 : unsigned(3 downto 0);
        variable dr, dg, db : integer;
        
        variable pix_x, pix_y : integer;
        variable pix_linear : integer;
        variable in_subblock1 : boolean;
        variable mod_msb, mod_lsb : std_logic;
        variable mod_idx : integer range 0 to 3;
        variable mod_val : integer;
        variable base_r, base_g, base_b : integer;
        variable table_idx : integer range 0 to 7;
        variable r_out, g_out, b_out, a_out : integer;
        variable alpha_nibble : unsigned(3 downto 0);
        variable texel_rgba : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            valid_out <= '0';
            decoded_texels <= (others => '0');
            
        elsif rising_edge(clk) then
            valid_out <= '0';
            
            case state is
                ---------------------------------------------------------------
                when IDLE =>
                    if valid_in = '1' then
                        -- Latch inputs
                        lat_format <= format;
                        lat_block_rgb <= block_rgb;
                        lat_block_alpha <= block_alpha;
                        
                        -- Decode block header
                        -- Note: ETC block is big-endian in spec, we assume input is already byte-swapped
                        diff_mode <= block_rgb(33);
                        flip_bit <= block_rgb(32);
                        table_idx0 <= to_integer(unsigned(block_rgb(39 downto 37)));
                        table_idx1 <= to_integer(unsigned(block_rgb(36 downto 34)));
                        
                        -- Decode base colors based on mode
                        if block_rgb(33) = '0' then
                            -- Individual mode: two 4-bit colors
                            r0_4 := unsigned(block_rgb(63 downto 60));
                            r1_4 := unsigned(block_rgb(59 downto 56));
                            g0_4 := unsigned(block_rgb(55 downto 52));
                            g1_4 := unsigned(block_rgb(51 downto 48));
                            b0_4 := unsigned(block_rgb(47 downto 44));
                            b1_4 := unsigned(block_rgb(43 downto 40));
                            
                            base_r0 <= expand_4to8(r0_4);
                            base_g0 <= expand_4to8(g0_4);
                            base_b0 <= expand_4to8(b0_4);
                            base_r1 <= expand_4to8(r1_4);
                            base_g1 <= expand_4to8(g1_4);
                            base_b1 <= expand_4to8(b1_4);
                        else
                            -- Differential mode: 5-bit base + 3-bit delta
                            r0_5 := unsigned(block_rgb(63 downto 59));
                            g0_5 := unsigned(block_rgb(55 downto 51));
                            b0_5 := unsigned(block_rgb(47 downto 43));
                            
                            dr := sign_extend_3(block_rgb(58 downto 56));
                            dg := sign_extend_3(block_rgb(50 downto 48));
                            db := sign_extend_3(block_rgb(42 downto 40));
                            
                            r1_5 := to_integer(r0_5) + dr;
                            g1_5 := to_integer(g0_5) + dg;
                            b1_5 := to_integer(b0_5) + db;
                            
                            -- Clamp and expand 5-bit to 8-bit
                            base_r0 <= expand_5to8(r0_5);
                            base_g0 <= expand_5to8(g0_5);
                            base_b0 <= expand_5to8(b0_5);
                            
                            if r1_5 >= 0 and r1_5 <= 31 then
                                base_r1 <= expand_5to8(to_unsigned(r1_5, 5));
                            else
                                base_r1 <= 0;
                            end if;
                            if g1_5 >= 0 and g1_5 <= 31 then
                                base_g1 <= expand_5to8(to_unsigned(g1_5, 5));
                            else
                                base_g1 <= 0;
                            end if;
                            if b1_5 >= 0 and b1_5 <= 31 then
                                base_b1 <= expand_5to8(to_unsigned(b1_5, 5));
                            else
                                base_b1 <= 0;
                            end if;
                        end if;
                        
                        state <= DECODE;
                    end if;
                
                ---------------------------------------------------------------
                when DECODE =>
                    -- Decode all 16 texels in parallel (combinatorially in one cycle)
                    for pix_y in 0 to 3 loop
                        for pix_x in 0 to 3 loop
                            pix_linear := pix_y * 4 + pix_x;
                            
                            -- Determine which subblock this pixel is in
                            if flip_bit = '0' then
                                -- Horizontal split: x < 2 is subblock 0
                                in_subblock1 := pix_x >= 2;
                            else
                                -- Vertical split: y < 2 is subblock 0
                                in_subblock1 := pix_y >= 2;
                            end if;
                            
                            -- Get base color and table index for this subblock
                            if in_subblock1 then
                                base_r := base_r1;
                                base_g := base_g1;
                                base_b := base_b1;
                                table_idx := table_idx1;
                            else
                                base_r := base_r0;
                                base_g := base_g0;
                                base_b := base_b0;
                                table_idx := table_idx0;
                            end if;
                            
                            -- Get modifier index from pixel index table
                            -- MSBs are in bits 16-31, LSBs are in bits 0-15
                            mod_msb := lat_block_rgb(pix_linear + 16);
                            mod_lsb := lat_block_rgb(pix_linear);
                            mod_idx := to_integer(unsigned'(mod_msb & mod_lsb));
                            
                            -- Look up modifier value
                            mod_val := ETC_MODIFIERS(table_idx, mod_idx);
                            
                            -- Apply modifier with clamping
                            r_out := clamp_255(base_r + mod_val);
                            g_out := clamp_255(base_g + mod_val);
                            b_out := clamp_255(base_b + mod_val);
                            
                            -- Handle alpha
                            if lat_format = "10" then
                                -- ETC2_RGBA: decode alpha from separate block
                                -- 4-bit alpha per pixel, expand to 8-bit
                                alpha_nibble := unsigned(lat_block_alpha(pix_linear*4+3 downto pix_linear*4));
                                a_out := to_integer(alpha_nibble & alpha_nibble);
                            else
                                -- ETC1 / ETC2_RGB: opaque
                                a_out := 255;
                            end if;
                            
                            -- Pack RGBA (R in MSB)
                            texel_rgba := std_logic_vector(to_unsigned(r_out, 8)) &
                                         std_logic_vector(to_unsigned(g_out, 8)) &
                                         std_logic_vector(to_unsigned(b_out, 8)) &
                                         std_logic_vector(to_unsigned(a_out, 8));
                            
                            -- Store in output array
                            decoded_texels((pix_linear+1)*32-1 downto pix_linear*32) <= texel_rgba;
                        end loop;
                    end loop;
                    
                    state <= OUTPUT;
                
                ---------------------------------------------------------------
                when OUTPUT =>
                    valid_out <= '1';
                    rgba_out <= decoded_texels;
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
