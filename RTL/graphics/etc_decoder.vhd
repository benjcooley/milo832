-------------------------------------------------------------------------------
-- etc_decoder.vhd
-- ETC1/ETC2 Texture Decompression
-- Decodes 4x4 pixel blocks from compressed format
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity etc_decoder is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Input: compressed block data
        valid_in        : in  std_logic;
        format          : in  std_logic_vector(1 downto 0);  -- 00=ETC1, 01=ETC2_RGB, 10=ETC2_RGBA
        block_rgb       : in  std_logic_vector(63 downto 0);   -- RGB block (64 bits)
        block_alpha     : in  std_logic_vector(63 downto 0);   -- Alpha block (64 bits, ETC2_RGBA only)
        
        -- Which texel within the 4x4 block to extract
        texel_x         : in  std_logic_vector(1 downto 0);    -- 0-3
        texel_y         : in  std_logic_vector(1 downto 0);    -- 0-3
        
        -- Output: decoded RGBA
        valid_out       : out std_logic;
        rgba_out        : out std_logic_vector(31 downto 0)
    );
end entity etc_decoder;

architecture rtl of etc_decoder is

    ---------------------------------------------------------------------------
    -- ETC1 Modifier Tables (per specification)
    ---------------------------------------------------------------------------
    type modifier_table_t is array (0 to 7, 0 to 3) of integer;
    constant ETC_MODIFIERS : modifier_table_t := (
        ( -8,  -2,   2,   8),
        (-17,  -5,   5,  17),
        (-29,  -9,   9,  29),
        (-42, -13,  13,  42),
        (-60, -18,  18,  60),
        (-80, -24,  24,  80),
        (-106, -33, 33, 106),
        (-183, -47, 47, 183)
    );
    
    ---------------------------------------------------------------------------
    -- Pipeline Registers
    ---------------------------------------------------------------------------
    signal valid_p1 : std_logic;
    signal format_p1 : std_logic_vector(1 downto 0);
    signal block_rgb_p1 : std_logic_vector(63 downto 0);
    signal block_alpha_p1 : std_logic_vector(63 downto 0);
    signal texel_x_p1, texel_y_p1 : unsigned(1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Decoded Values
    ---------------------------------------------------------------------------
    signal base_r, base_g, base_b : unsigned(7 downto 0);
    signal modifier_idx : integer range 0 to 7;
    signal pixel_idx : integer range 0 to 3;
    signal modifier_val : integer;
    signal is_diff_mode : std_logic;
    signal flip_bit : std_logic;
    signal in_subblock_1 : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Stage 1: Latch inputs and decode block header
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable diff : std_logic;
        variable r1, g1, b1 : unsigned(4 downto 0);
        variable dr, dg, db : signed(2 downto 0);
        variable r2, g2, b2 : unsigned(4 downto 0);
        variable table_idx1, table_idx2 : unsigned(2 downto 0);
    begin
        if rst_n = '0' then
            valid_p1 <= '0';
            
        elsif rising_edge(clk) then
            valid_p1 <= valid_in;
            format_p1 <= format;
            block_rgb_p1 <= block_rgb;
            block_alpha_p1 <= block_alpha;
            texel_x_p1 <= unsigned(texel_x);
            texel_y_p1 <= unsigned(texel_y);
            
            if valid_in = '1' then
                -- Decode ETC1/ETC2 block header
                -- Bit 33 = diff mode, Bit 32 = flip
                diff := block_rgb(33);
                flip_bit <= block_rgb(32);
                is_diff_mode <= diff;
                
                -- Get modifier table indices
                table_idx1 := unsigned(block_rgb(39 downto 37));
                table_idx2 := unsigned(block_rgb(36 downto 34));
                
                -- Determine which subblock this texel is in
                if block_rgb(32) = '0' then
                    -- Flip = 0: left/right split (x < 2 = subblock 0)
                    if unsigned(texel_x) < 2 then
                        in_subblock_1 <= '0';
                        modifier_idx <= to_integer(table_idx1);
                    else
                        in_subblock_1 <= '1';
                        modifier_idx <= to_integer(table_idx2);
                    end if;
                else
                    -- Flip = 1: top/bottom split (y < 2 = subblock 0)
                    if unsigned(texel_y) < 2 then
                        in_subblock_1 <= '0';
                        modifier_idx <= to_integer(table_idx1);
                    else
                        in_subblock_1 <= '1';
                        modifier_idx <= to_integer(table_idx2);
                    end if;
                end if;
                
                -- Decode base colors
                if diff = '0' then
                    -- Individual mode: two separate 4-bit colors
                    r1 := unsigned(block_rgb(63 downto 60)) & "0";
                    g1 := unsigned(block_rgb(55 downto 52)) & "0";
                    b1 := unsigned(block_rgb(47 downto 44)) & "0";
                    
                    r2 := unsigned(block_rgb(59 downto 56)) & "0";
                    g2 := unsigned(block_rgb(51 downto 48)) & "0";
                    b2 := unsigned(block_rgb(43 downto 40)) & "0";
                    
                    if unsigned(texel_x) < 2 xor unsigned(texel_y) < 2 xor block_rgb(32) = '1' then
                        base_r <= r1 & r1(4 downto 2);
                        base_g <= g1 & g1(4 downto 2);
                        base_b <= b1 & b1(4 downto 2);
                    else
                        base_r <= r2 & r2(4 downto 2);
                        base_g <= g2 & g2(4 downto 2);
                        base_b <= b2 & b2(4 downto 2);
                    end if;
                else
                    -- Differential mode: 5-bit base + 3-bit delta
                    r1 := unsigned(block_rgb(63 downto 59));
                    g1 := unsigned(block_rgb(55 downto 51));
                    b1 := unsigned(block_rgb(47 downto 43));
                    
                    dr := signed(block_rgb(58 downto 56));
                    dg := signed(block_rgb(50 downto 48));
                    db := signed(block_rgb(42 downto 40));
                    
                    r2 := resize(unsigned(resize(signed('0' & r1), 6) + resize(dr, 6)), 5);
                    g2 := resize(unsigned(resize(signed('0' & g1), 6) + resize(dg, 6)), 5);
                    b2 := resize(unsigned(resize(signed('0' & b1), 6) + resize(db, 6)), 5);
                    
                    -- Expand 5-bit to 8-bit
                    if in_subblock_1 = '0' then
                        base_r <= r1 & r1(4 downto 2);
                        base_g <= g1 & g1(4 downto 2);
                        base_b <= b1 & b1(4 downto 2);
                    else
                        base_r <= r2 & r2(4 downto 2);
                        base_g <= g2 & g2(4 downto 2);
                        base_b <= b2 & b2(4 downto 2);
                    end if;
                end if;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Stage 2: Apply modifier and output
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable pix_linear : integer;
        variable msb_idx, lsb_idx : integer;
        variable mod_bits : std_logic_vector(1 downto 0);
        variable mod_value : integer;
        variable r_out, g_out, b_out : integer;
        variable alpha_out : unsigned(7 downto 0);
        variable alpha_idx : integer;
    begin
        if rst_n = '0' then
            valid_out <= '0';
            rgba_out <= (others => '0');
            
        elsif rising_edge(clk) then
            valid_out <= valid_p1;
            
            if valid_p1 = '1' then
                -- Calculate linear pixel index (0-15) within block
                pix_linear := to_integer(texel_y_p1) * 4 + to_integer(texel_x_p1);
                
                -- Get modifier bits from pixel index table
                -- LSBs are in bits 0-15, MSBs are in bits 16-31
                lsb_idx := pix_linear;
                msb_idx := pix_linear + 16;
                mod_bits := block_rgb_p1(msb_idx) & block_rgb_p1(lsb_idx);
                
                -- Look up modifier value
                mod_value := ETC_MODIFIERS(modifier_idx, to_integer(unsigned(mod_bits)));
                
                -- Apply modifier to base color with clamping
                r_out := to_integer(base_r) + mod_value;
                g_out := to_integer(base_g) + mod_value;
                b_out := to_integer(base_b) + mod_value;
                
                -- Clamp to 0-255
                if r_out < 0 then r_out := 0; elsif r_out > 255 then r_out := 255; end if;
                if g_out < 0 then g_out := 0; elsif g_out > 255 then g_out := 255; end if;
                if b_out < 0 then b_out := 0; elsif b_out > 255 then b_out := 255; end if;
                
                -- Handle alpha
                if format_p1 = "10" then
                    -- ETC2_RGBA: decode alpha from separate block
                    -- Simple 4-bit alpha per pixel in 64-bit block
                    alpha_idx := pix_linear * 4;
                    alpha_out := unsigned(block_alpha_p1(alpha_idx+3 downto alpha_idx)) & 
                                unsigned(block_alpha_p1(alpha_idx+3 downto alpha_idx));
                else
                    -- ETC1 / ETC2_RGB: opaque
                    alpha_out := x"FF";
                end if;
                
                rgba_out <= std_logic_vector(to_unsigned(r_out, 8)) &
                           std_logic_vector(to_unsigned(g_out, 8)) &
                           std_logic_vector(to_unsigned(b_out, 8)) &
                           std_logic_vector(alpha_out);
            end if;
        end if;
    end process;

end architecture rtl;
