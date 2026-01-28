-------------------------------------------------------------------------------
-- texture_sampler.vhd
-- Texture Sampling Unit with Bilinear Filtering
-- Supports multiple texture formats and mipmapping
--
-- New component for Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity texture_sampler is
    generic (
        -- Texture cache parameters
        CACHE_SIZE_KB   : integer := 16;
        CACHE_LINE_SIZE : integer := 64;    -- bytes
        
        -- Maximum texture dimensions
        MAX_TEX_WIDTH   : integer := 2048;
        MAX_TEX_HEIGHT  : integer := 2048;
        MAX_MIP_LEVELS  : integer := 11;    -- log2(2048) + 1
        
        -- Fixed point precision for coordinates (16.16)
        COORD_FRAC_BITS : integer := 16
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Sample request interface
        req_valid       : in  std_logic;
        req_ready       : out std_logic;
        
        -- Texture coordinates (16.16 fixed point, normalized 0.0 to 1.0)
        req_u           : in  std_logic_vector(31 downto 0);
        req_v           : in  std_logic_vector(31 downto 0);
        req_lod         : in  std_logic_vector(7 downto 0);   -- LOD level (0 = base)
        
        -- Texture configuration
        tex_base_addr   : in  std_logic_vector(31 downto 0);  -- Base address in memory
        tex_width       : in  std_logic_vector(11 downto 0);  -- Width in pixels
        tex_height      : in  std_logic_vector(11 downto 0);  -- Height in pixels
        tex_format      : in  std_logic_vector(3 downto 0);   -- Texture format
        tex_wrap_u      : in  std_logic_vector(1 downto 0);   -- U wrap mode
        tex_wrap_v      : in  std_logic_vector(1 downto 0);   -- V wrap mode
        tex_filter      : in  std_logic;                       -- 0=nearest, 1=bilinear
        
        -- Sample result
        sample_valid    : out std_logic;
        sample_color    : out std_logic_vector(31 downto 0);  -- RGBA8888
        
        -- Memory interface (to texture memory/cache)
        mem_req_valid   : out std_logic;
        mem_req_addr    : out std_logic_vector(31 downto 0);
        mem_req_ready   : in  std_logic;
        mem_resp_valid  : in  std_logic;
        mem_resp_data   : in  std_logic_vector(31 downto 0);
        
        -- Status
        cache_hits      : out std_logic_vector(31 downto 0);
        cache_misses    : out std_logic_vector(31 downto 0)
    );
end entity texture_sampler;

architecture rtl of texture_sampler is

    ---------------------------------------------------------------------------
    -- Texture Formats
    ---------------------------------------------------------------------------
    constant FMT_RGBA8888   : std_logic_vector(3 downto 0) := "0000";  -- 32 bpp
    constant FMT_RGB888     : std_logic_vector(3 downto 0) := "0001";  -- 24 bpp
    constant FMT_RGB565     : std_logic_vector(3 downto 0) := "0010";  -- 16 bpp
    constant FMT_RGBA4444   : std_logic_vector(3 downto 0) := "0011";  -- 16 bpp
    constant FMT_RGBA5551   : std_logic_vector(3 downto 0) := "0100";  -- 16 bpp
    constant FMT_L8         : std_logic_vector(3 downto 0) := "0101";  -- 8 bpp luminance
    constant FMT_A8         : std_logic_vector(3 downto 0) := "0110";  -- 8 bpp alpha
    constant FMT_LA88       : std_logic_vector(3 downto 0) := "0111";  -- 16 bpp lum+alpha
    
    ---------------------------------------------------------------------------
    -- Wrap Modes
    ---------------------------------------------------------------------------
    constant WRAP_REPEAT    : std_logic_vector(1 downto 0) := "00";
    constant WRAP_CLAMP     : std_logic_vector(1 downto 0) := "01";
    constant WRAP_MIRROR    : std_logic_vector(1 downto 0) := "10";
    constant WRAP_BORDER    : std_logic_vector(1 downto 0) := "11";
    
    ---------------------------------------------------------------------------
    -- State Machine
    ---------------------------------------------------------------------------
    type state_t is (
        IDLE,
        CALC_ADDRESS,       -- Calculate texel addresses
        FETCH_TEXEL_0,      -- Fetch first texel
        FETCH_TEXEL_1,      -- Fetch second texel (bilinear)
        FETCH_TEXEL_2,      -- Fetch third texel (bilinear)
        FETCH_TEXEL_3,      -- Fetch fourth texel (bilinear)
        WAIT_MEM,           -- Wait for memory response
        FILTER,             -- Apply filtering
        OUTPUT              -- Output result
    );
    signal state : state_t := IDLE;
    
    ---------------------------------------------------------------------------
    -- Coordinate Processing
    ---------------------------------------------------------------------------
    signal coord_u, coord_v : signed(31 downto 0);
    signal texel_u, texel_v : unsigned(11 downto 0);        -- Integer texel coordinates
    signal frac_u, frac_v : unsigned(15 downto 0);          -- Fractional parts for filtering
    
    -- For bilinear filtering, we need 4 texel coordinates
    signal texel_u0, texel_u1 : unsigned(11 downto 0);
    signal texel_v0, texel_v1 : unsigned(11 downto 0);
    
    ---------------------------------------------------------------------------
    -- Texel Data
    ---------------------------------------------------------------------------
    signal texel_00, texel_10 : std_logic_vector(31 downto 0);  -- Top row
    signal texel_01, texel_11 : std_logic_vector(31 downto 0);  -- Bottom row
    signal texels_fetched : unsigned(1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Filtering
    ---------------------------------------------------------------------------
    signal filtered_color : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Statistics
    ---------------------------------------------------------------------------
    signal hit_count, miss_count : unsigned(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Configuration latches
    ---------------------------------------------------------------------------
    signal lat_base_addr : std_logic_vector(31 downto 0);
    signal lat_width, lat_height : unsigned(11 downto 0);
    signal lat_format : std_logic_vector(3 downto 0);
    signal lat_wrap_u, lat_wrap_v : std_logic_vector(1 downto 0);
    signal lat_filter : std_logic;
    signal lat_lod : unsigned(7 downto 0);
    
    ---------------------------------------------------------------------------
    -- Helper function: Apply wrap mode to coordinate
    ---------------------------------------------------------------------------
    function apply_wrap(
        coord : signed(31 downto 0);
        size : unsigned(11 downto 0);
        wrap_mode : std_logic_vector(1 downto 0)
    ) return unsigned is
        variable result : integer;
        variable coord_int : integer;
        variable size_int : integer;
    begin
        size_int := to_integer(size);
        if size_int = 0 then
            return to_unsigned(0, 12);
        end if;
        
        -- Extract integer part (coordinate is in 16.16 fixed point, normalized)
        -- Multiply by texture size to get texel coordinate
        coord_int := to_integer(shift_right(coord * signed(resize(size, 32)), COORD_FRAC_BITS));
        
        case wrap_mode is
            when WRAP_REPEAT =>
                result := coord_int mod size_int;
                if result < 0 then
                    result := result + size_int;
                end if;
                
            when WRAP_CLAMP =>
                if coord_int < 0 then
                    result := 0;
                elsif coord_int >= size_int then
                    result := size_int - 1;
                else
                    result := coord_int;
                end if;
                
            when WRAP_MIRROR =>
                result := coord_int mod (2 * size_int);
                if result < 0 then
                    result := result + 2 * size_int;
                end if;
                if result >= size_int then
                    result := 2 * size_int - 1 - result;
                end if;
                
            when others =>  -- WRAP_BORDER
                if coord_int < 0 or coord_int >= size_int then
                    result := -1;  -- Border color flag
                else
                    result := coord_int;
                end if;
        end case;
        
        if result < 0 then
            return to_unsigned(0, 12);
        else
            return to_unsigned(result, 12);
        end if;
    end function;
    
    ---------------------------------------------------------------------------
    -- Helper function: Calculate bytes per pixel
    ---------------------------------------------------------------------------
    function get_bpp(format : std_logic_vector(3 downto 0)) return integer is
    begin
        case format is
            when FMT_RGBA8888 => return 4;
            when FMT_RGB888   => return 3;
            when FMT_RGB565   => return 2;
            when FMT_RGBA4444 => return 2;
            when FMT_RGBA5551 => return 2;
            when FMT_L8       => return 1;
            when FMT_A8       => return 1;
            when FMT_LA88     => return 2;
            when others       => return 4;
        end case;
    end function;
    
    ---------------------------------------------------------------------------
    -- Helper function: Convert texture data to RGBA8888
    ---------------------------------------------------------------------------
    function convert_to_rgba(
        data : std_logic_vector(31 downto 0);
        format : std_logic_vector(3 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
        variable r, g, b, a : unsigned(7 downto 0);
    begin
        case format is
            when FMT_RGBA8888 =>
                result := data;
                
            when FMT_RGB888 =>
                result := data(23 downto 0) & x"FF";
                
            when FMT_RGB565 =>
                -- R: 5 bits, G: 6 bits, B: 5 bits
                r := unsigned(data(15 downto 11)) & "000";
                g := unsigned(data(10 downto 5)) & "00";
                b := unsigned(data(4 downto 0)) & "000";
                result := std_logic_vector(r) & std_logic_vector(g) & 
                         std_logic_vector(b) & x"FF";
                
            when FMT_RGBA4444 =>
                r := unsigned(data(15 downto 12)) & unsigned(data(15 downto 12));
                g := unsigned(data(11 downto 8)) & unsigned(data(11 downto 8));
                b := unsigned(data(7 downto 4)) & unsigned(data(7 downto 4));
                a := unsigned(data(3 downto 0)) & unsigned(data(3 downto 0));
                result := std_logic_vector(r) & std_logic_vector(g) & 
                         std_logic_vector(b) & std_logic_vector(a);
                
            when FMT_RGBA5551 =>
                r := unsigned(data(15 downto 11)) & "000";
                g := unsigned(data(10 downto 6)) & "000";
                b := unsigned(data(5 downto 1)) & "000";
                if data(0) = '1' then
                    a := x"FF";
                else
                    a := x"00";
                end if;
                result := std_logic_vector(r) & std_logic_vector(g) & 
                         std_logic_vector(b) & std_logic_vector(a);
                
            when FMT_L8 =>
                -- Luminance to RGB
                result := data(7 downto 0) & data(7 downto 0) & 
                         data(7 downto 0) & x"FF";
                
            when FMT_A8 =>
                -- Alpha only
                result := x"FFFFFF" & data(7 downto 0);
                
            when FMT_LA88 =>
                -- Luminance + Alpha
                result := data(15 downto 8) & data(15 downto 8) & 
                         data(15 downto 8) & data(7 downto 0);
                
            when others =>
                result := data;
        end case;
        
        return result;
    end function;
    
    ---------------------------------------------------------------------------
    -- Helper function: Bilinear interpolation for one channel
    ---------------------------------------------------------------------------
    function bilinear_interp(
        c00, c10, c01, c11 : unsigned(7 downto 0);
        frac_u, frac_v : unsigned(15 downto 0)
    ) return unsigned is
        variable u_frac, v_frac : unsigned(7 downto 0);
        variable u_inv, v_inv : unsigned(7 downto 0);
        variable top, bottom : unsigned(15 downto 0);
        variable result : unsigned(15 downto 0);
    begin
        -- Use 8-bit fractional parts (0-255)
        u_frac := frac_u(15 downto 8);
        v_frac := frac_v(15 downto 8);
        u_inv := 255 - u_frac;
        v_inv := 255 - v_frac;
        
        -- Interpolate top row: (c00 * (255-fu) + c10 * fu) / 256
        top := resize(c00 * u_inv + c10 * u_frac, 16);
        
        -- Interpolate bottom row
        bottom := resize(c01 * u_inv + c11 * u_frac, 16);
        
        -- Interpolate between rows
        result := resize(top(15 downto 8) * v_inv + bottom(15 downto 8) * v_frac, 16);
        
        return result(15 downto 8);
    end function;

begin

    -- Output assignments
    req_ready <= '1' when state = IDLE else '0';
    cache_hits <= std_logic_vector(hit_count);
    cache_misses <= std_logic_vector(miss_count);
    
    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable addr_offset : unsigned(31 downto 0);
        variable texel_addr : unsigned(31 downto 0);
        variable bpp : integer;
        variable rgba_00, rgba_10, rgba_01, rgba_11 : std_logic_vector(31 downto 0);
        variable r, g, b, a : unsigned(7 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            sample_valid <= '0';
            sample_color <= (others => '0');
            mem_req_valid <= '0';
            mem_req_addr <= (others => '0');
            hit_count <= (others => '0');
            miss_count <= (others => '0');
            texels_fetched <= (others => '0');
            
        elsif rising_edge(clk) then
            case state is
                ---------------------------------------------------------------
                when IDLE =>
                    sample_valid <= '0';
                    mem_req_valid <= '0';
                    
                    -- synthesis translate_off
                    if req_valid = '1' then
                        report "SAMPLER: req_valid, transitioning to CALC_ADDRESS";
                    end if;
                    -- synthesis translate_on
                    
                    if req_valid = '1' then
                        -- Latch configuration
                        lat_base_addr <= tex_base_addr;
                        lat_width <= unsigned(tex_width);
                        lat_height <= unsigned(tex_height);
                        lat_format <= tex_format;
                        lat_wrap_u <= tex_wrap_u;
                        lat_wrap_v <= tex_wrap_v;
                        lat_filter <= tex_filter;
                        lat_lod <= unsigned(req_lod);
                        
                        -- Latch coordinates
                        coord_u <= signed(req_u);
                        coord_v <= signed(req_v);
                        
                        state <= CALC_ADDRESS;
                    end if;
                
                ---------------------------------------------------------------
                when CALC_ADDRESS =>
                    -- synthesis translate_off
                    report "SAMPLER: CALC_ADDRESS";
                    -- synthesis translate_on
                    
                    -- Calculate texel coordinates with wrapping
                    texel_u0 <= apply_wrap(coord_u, lat_width, lat_wrap_u);
                    texel_v0 <= apply_wrap(coord_v, lat_height, lat_wrap_v);
                    
                    -- For bilinear filtering, calculate adjacent texels
                    if lat_filter = '1' then
                        texel_u1 <= apply_wrap(coord_u + to_signed(65536, 32), lat_width, lat_wrap_u);
                        texel_v1 <= apply_wrap(coord_v + to_signed(65536, 32), lat_height, lat_wrap_v);
                        
                        -- Extract fractional parts for filtering weights
                        frac_u <= unsigned(coord_u(COORD_FRAC_BITS-1 downto 0));
                        frac_v <= unsigned(coord_v(COORD_FRAC_BITS-1 downto 0));
                    end if;
                    
                    texels_fetched <= (others => '0');
                    state <= FETCH_TEXEL_0;
                
                ---------------------------------------------------------------
                when FETCH_TEXEL_0 =>
                    -- Calculate address for texel (u0, v0)
                    bpp := get_bpp(lat_format);
                    addr_offset := resize(resize(texel_v0 * lat_width + texel_u0, 32) * 
                                          to_unsigned(bpp, 32), 32);
                    texel_addr := unsigned(lat_base_addr) + addr_offset;
                    
                    mem_req_valid <= '1';
                    mem_req_addr <= std_logic_vector(texel_addr);
                    state <= WAIT_MEM;  -- Always transition, request is held for 1 cycle
                
                ---------------------------------------------------------------
                when FETCH_TEXEL_1 =>
                    -- Calculate address for texel (u1, v0)
                    bpp := get_bpp(lat_format);
                    addr_offset := resize(resize(texel_v0 * lat_width + texel_u1, 32) * 
                                          to_unsigned(bpp, 32), 32);
                    texel_addr := unsigned(lat_base_addr) + addr_offset;
                    
                    mem_req_valid <= '1';
                    mem_req_addr <= std_logic_vector(texel_addr);
                    state <= WAIT_MEM;
                
                ---------------------------------------------------------------
                when FETCH_TEXEL_2 =>
                    -- Calculate address for texel (u0, v1)
                    bpp := get_bpp(lat_format);
                    addr_offset := resize(resize(texel_v1 * lat_width + texel_u0, 32) * 
                                          to_unsigned(bpp, 32), 32);
                    texel_addr := unsigned(lat_base_addr) + addr_offset;
                    
                    mem_req_valid <= '1';
                    mem_req_addr <= std_logic_vector(texel_addr);
                    state <= WAIT_MEM;
                
                ---------------------------------------------------------------
                when FETCH_TEXEL_3 =>
                    -- Calculate address for texel (u1, v1)
                    bpp := get_bpp(lat_format);
                    addr_offset := resize(resize(texel_v1 * lat_width + texel_u1, 32) * 
                                          to_unsigned(bpp, 32), 32);
                    texel_addr := unsigned(lat_base_addr) + addr_offset;
                    
                    mem_req_valid <= '1';
                    mem_req_addr <= std_logic_vector(texel_addr);
                    state <= WAIT_MEM;
                
                ---------------------------------------------------------------
                when WAIT_MEM =>
                    mem_req_valid <= '0';  -- Clear request
                    
                    -- synthesis translate_off
                    report "SAMPLER: WAIT_MEM, mem_resp_valid=" & std_logic'image(mem_resp_valid);
                    -- synthesis translate_on
                    
                    if mem_resp_valid = '1' then
                        miss_count <= miss_count + 1;
                        
                        -- Store texel data based on fetch stage
                        case texels_fetched is
                            when "00" =>
                                texel_00 <= convert_to_rgba(mem_resp_data, lat_format);
                                texels_fetched <= "01";
                                if lat_filter = '1' then
                                    state <= FETCH_TEXEL_1;
                                else
                                    state <= FILTER;
                                end if;
                                
                            when "01" =>
                                texel_10 <= convert_to_rgba(mem_resp_data, lat_format);
                                texels_fetched <= "10";
                                state <= FETCH_TEXEL_2;
                                
                            when "10" =>
                                texel_01 <= convert_to_rgba(mem_resp_data, lat_format);
                                texels_fetched <= "11";
                                state <= FETCH_TEXEL_3;
                                
                            when others =>
                                texel_11 <= convert_to_rgba(mem_resp_data, lat_format);
                                state <= FILTER;
                        end case;
                    end if;
                
                ---------------------------------------------------------------
                when FILTER =>
                    if lat_filter = '1' then
                        -- Bilinear filtering
                        r := bilinear_interp(
                            unsigned(texel_00(31 downto 24)),
                            unsigned(texel_10(31 downto 24)),
                            unsigned(texel_01(31 downto 24)),
                            unsigned(texel_11(31 downto 24)),
                            frac_u, frac_v
                        );
                        
                        g := bilinear_interp(
                            unsigned(texel_00(23 downto 16)),
                            unsigned(texel_10(23 downto 16)),
                            unsigned(texel_01(23 downto 16)),
                            unsigned(texel_11(23 downto 16)),
                            frac_u, frac_v
                        );
                        
                        b := bilinear_interp(
                            unsigned(texel_00(15 downto 8)),
                            unsigned(texel_10(15 downto 8)),
                            unsigned(texel_01(15 downto 8)),
                            unsigned(texel_11(15 downto 8)),
                            frac_u, frac_v
                        );
                        
                        a := bilinear_interp(
                            unsigned(texel_00(7 downto 0)),
                            unsigned(texel_10(7 downto 0)),
                            unsigned(texel_01(7 downto 0)),
                            unsigned(texel_11(7 downto 0)),
                            frac_u, frac_v
                        );
                        
                        filtered_color <= std_logic_vector(r) & std_logic_vector(g) & 
                                         std_logic_vector(b) & std_logic_vector(a);
                    else
                        -- Nearest neighbor (just use texel_00)
                        filtered_color <= texel_00;
                    end if;
                    
                    state <= OUTPUT;
                
                ---------------------------------------------------------------
                when OUTPUT =>
                    -- synthesis translate_off
                    report "SAMPLER: OUTPUT, color=" & to_hstring(filtered_color);
                    -- synthesis translate_on
                    
                    sample_valid <= '1';
                    sample_color <= filtered_color;
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
