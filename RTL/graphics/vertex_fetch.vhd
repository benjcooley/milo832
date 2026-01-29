-------------------------------------------------------------------------------
-- vertex_fetch.vhd
-- Vertex Fetch / Input Assembler Unit
--
-- Fetches vertex data from memory based on index buffer (indexed drawing)
-- or generates sequential indices (non-indexed drawing).
-- Outputs vertices ready for vertex shader or direct rasterization.
--
-- Features:
--   - Index buffer fetch (8/16/32-bit indices)
--   - Vertex buffer fetch with configurable stride
--   - Multiple vertex attributes support
--   - Primitive assembly (triangles, triangle strips, triangle fans)
--
-- Milo832 GPU project - Graphics coprocessor for m65832 CPU
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vertex_fetch is
    generic (
        MAX_ATTRIBS     : integer := 8;     -- Maximum vertex attributes
        MAX_STREAMS     : integer := 4      -- Maximum vertex buffer streams
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Draw Command Input
        -----------------------------------------------------------------------
        draw_valid      : in  std_logic;
        draw_ready      : out std_logic;
        draw_indexed    : in  std_logic;                        -- 1 = indexed, 0 = non-indexed
        draw_prim_type  : in  std_logic_vector(2 downto 0);     -- Primitive type
        draw_start      : in  std_logic_vector(31 downto 0);    -- Start index/vertex
        draw_count      : in  std_logic_vector(31 downto 0);    -- Number of indices/vertices
        draw_base_vert  : in  std_logic_vector(31 downto 0);    -- Base vertex (added to index)
        
        -----------------------------------------------------------------------
        -- Index Buffer Configuration
        -----------------------------------------------------------------------
        idx_buf_addr    : in  std_logic_vector(31 downto 0);    -- Index buffer base address
        idx_buf_format  : in  std_logic_vector(1 downto 0);     -- 00=U8, 01=U16, 10=U32
        
        -----------------------------------------------------------------------
        -- Vertex Buffer Configuration (Stream 0 for simplicity)
        -----------------------------------------------------------------------
        vtx_buf_addr    : in  std_logic_vector(31 downto 0);    -- Vertex buffer base address
        vtx_buf_stride  : in  std_logic_vector(7 downto 0);     -- Bytes per vertex
        
        -- Attribute layout (offset within vertex, currently position only)
        attr_pos_offset : in  std_logic_vector(7 downto 0);     -- Position offset (xyz, 12 bytes)
        attr_uv_offset  : in  std_logic_vector(7 downto 0);     -- UV offset (2 floats, 8 bytes)
        attr_color_off  : in  std_logic_vector(7 downto 0);     -- Color offset (rgba, 4 bytes)
        attr_enable     : in  std_logic_vector(2 downto 0);     -- [2]=color, [1]=uv, [0]=position
        
        -----------------------------------------------------------------------
        -- Memory Read Interface
        -----------------------------------------------------------------------
        mem_rd_addr     : out std_logic_vector(31 downto 0);
        mem_rd_en       : out std_logic;
        mem_rd_size     : out std_logic_vector(1 downto 0);     -- 00=byte, 01=half, 10=word
        mem_rd_data     : in  std_logic_vector(31 downto 0);
        mem_rd_valid    : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Vertex Output (to vertex shader or primitive assembly)
        -----------------------------------------------------------------------
        vtx_valid       : out std_logic;
        vtx_ready       : in  std_logic;
        vtx_index       : out std_logic_vector(31 downto 0);    -- Original vertex index
        vtx_pos_x       : out std_logic_vector(31 downto 0);    -- Position X (float32)
        vtx_pos_y       : out std_logic_vector(31 downto 0);    -- Position Y (float32)
        vtx_pos_z       : out std_logic_vector(31 downto 0);    -- Position Z (float32)
        vtx_uv_u        : out std_logic_vector(31 downto 0);    -- Texture U (float32)
        vtx_uv_v        : out std_logic_vector(31 downto 0);    -- Texture V (float32)
        vtx_color       : out std_logic_vector(31 downto 0);    -- Vertex color (RGBA8)
        
        -----------------------------------------------------------------------
        -- Status
        -----------------------------------------------------------------------
        fetch_busy      : out std_logic;
        vertices_fetched: out std_logic_vector(31 downto 0)
    );
end entity vertex_fetch;

architecture rtl of vertex_fetch is

    -- Primitive types
    constant PRIM_TRIANGLES     : std_logic_vector(2 downto 0) := "000";
    constant PRIM_TRIANGLE_STRIP: std_logic_vector(2 downto 0) := "001";
    constant PRIM_TRIANGLE_FAN  : std_logic_vector(2 downto 0) := "010";
    constant PRIM_POINTS        : std_logic_vector(2 downto 0) := "011";
    constant PRIM_LINES         : std_logic_vector(2 downto 0) := "100";
    
    -- Index formats
    constant IDX_U8  : std_logic_vector(1 downto 0) := "00";
    constant IDX_U16 : std_logic_vector(1 downto 0) := "01";
    constant IDX_U32 : std_logic_vector(1 downto 0) := "10";
    
    -- FSM states
    type state_t is (
        IDLE,
        FETCH_INDEX,
        WAIT_INDEX,
        CALC_VTX_ADDR,
        FETCH_POS_X,
        WAIT_POS_X,
        FETCH_POS_Y,
        WAIT_POS_Y,
        FETCH_POS_Z,
        WAIT_POS_Z,
        FETCH_UV_U,
        WAIT_UV_U,
        FETCH_UV_V,
        WAIT_UV_V,
        FETCH_COLOR,
        WAIT_COLOR,
        OUTPUT_VERTEX
    );
    signal state : state_t := IDLE;
    
    -- Draw parameters (latched)
    signal draw_indexed_r   : std_logic;
    signal draw_prim_type_r : std_logic_vector(2 downto 0);
    signal draw_start_r     : unsigned(31 downto 0);
    signal draw_count_r     : unsigned(31 downto 0);
    signal draw_base_vert_r : unsigned(31 downto 0);
    signal attr_enable_r    : std_logic_vector(2 downto 0);
    
    -- Fetch counters
    signal current_idx      : unsigned(31 downto 0);
    signal vertices_done    : unsigned(31 downto 0);
    
    -- Current vertex data
    signal vertex_index     : unsigned(31 downto 0);
    signal vertex_addr      : unsigned(31 downto 0);
    signal pos_x, pos_y, pos_z : std_logic_vector(31 downto 0);
    signal uv_u, uv_v       : std_logic_vector(31 downto 0);
    signal color            : std_logic_vector(31 downto 0);
    
    -- Memory read request
    signal mem_addr         : std_logic_vector(31 downto 0);
    signal mem_en           : std_logic;
    signal mem_size         : std_logic_vector(1 downto 0);
    
begin

    mem_rd_addr <= mem_addr;
    mem_rd_en <= mem_en;
    mem_rd_size <= mem_size;
    
    vtx_index <= std_logic_vector(vertex_index);
    vtx_pos_x <= pos_x;
    vtx_pos_y <= pos_y;
    vtx_pos_z <= pos_z;
    vtx_uv_u <= uv_u;
    vtx_uv_v <= uv_v;
    vtx_color <= color;
    
    fetch_busy <= '0' when state = IDLE else '1';
    vertices_fetched <= std_logic_vector(vertices_done);
    
    -- Main FSM
    process(clk, rst_n)
        variable idx_byte_size : unsigned(1 downto 0);
        variable idx_addr : unsigned(31 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            draw_ready <= '1';
            vtx_valid <= '0';
            mem_en <= '0';
            mem_addr <= (others => '0');
            mem_size <= "10";  -- word
            current_idx <= (others => '0');
            vertices_done <= (others => '0');
            vertex_index <= (others => '0');
            vertex_addr <= (others => '0');
            pos_x <= (others => '0');
            pos_y <= (others => '0');
            pos_z <= (others => '0');
            uv_u <= (others => '0');
            uv_v <= (others => '0');
            color <= x"FFFFFFFF";  -- Default white
            draw_indexed_r <= '0';
            draw_prim_type_r <= "000";
            draw_start_r <= (others => '0');
            draw_count_r <= (others => '0');
            draw_base_vert_r <= (others => '0');
            attr_enable_r <= "001";  -- Position only by default
            
        elsif rising_edge(clk) then
            mem_en <= '0';
            vtx_valid <= '0';
            
            case state is
                when IDLE =>
                    draw_ready <= '1';
                    
                    if draw_valid = '1' and draw_ready = '1' then
                        -- Latch draw parameters
                        draw_indexed_r <= draw_indexed;
                        draw_prim_type_r <= draw_prim_type;
                        draw_start_r <= unsigned(draw_start);
                        draw_count_r <= unsigned(draw_count);
                        draw_base_vert_r <= unsigned(draw_base_vert);
                        attr_enable_r <= attr_enable;
                        
                        current_idx <= unsigned(draw_start);
                        vertices_done <= (others => '0');
                        draw_ready <= '0';
                        
                        if unsigned(draw_count) > 0 then
                            if draw_indexed = '1' then
                                state <= FETCH_INDEX;
                            else
                                -- Non-indexed: vertex index = sequential
                                vertex_index <= unsigned(draw_start) + unsigned(draw_base_vert);
                                state <= CALC_VTX_ADDR;
                            end if;
                        end if;
                    end if;
                
                ---------------------------------------------------------------
                -- Index fetch path
                ---------------------------------------------------------------
                when FETCH_INDEX =>
                    -- Calculate index buffer address
                    case idx_buf_format is
                        when IDX_U8 =>
                            idx_byte_size := "01";
                            idx_addr := unsigned(idx_buf_addr) + current_idx;
                            mem_size <= "00";  -- byte
                        when IDX_U16 =>
                            idx_byte_size := "10";
                            idx_addr := unsigned(idx_buf_addr) + shift_left(current_idx, 1);  -- *2
                            mem_size <= "01";  -- halfword
                        when others =>  -- IDX_U32
                            idx_byte_size := "00";
                            idx_addr := unsigned(idx_buf_addr) + shift_left(current_idx, 2);  -- *4
                            mem_size <= "10";  -- word
                    end case;
                    
                    mem_addr <= std_logic_vector(idx_addr);
                    mem_en <= '1';
                    state <= WAIT_INDEX;
                
                when WAIT_INDEX =>
                    if mem_rd_valid = '1' then
                        -- Extract vertex index based on format
                        case idx_buf_format is
                            when IDX_U8 =>
                                vertex_index <= draw_base_vert_r + unsigned(x"000000" & mem_rd_data(7 downto 0));
                            when IDX_U16 =>
                                vertex_index <= draw_base_vert_r + unsigned(x"0000" & mem_rd_data(15 downto 0));
                            when others =>
                                vertex_index <= draw_base_vert_r + unsigned(mem_rd_data);
                        end case;
                        state <= CALC_VTX_ADDR;
                    end if;
                
                ---------------------------------------------------------------
                -- Vertex data fetch
                ---------------------------------------------------------------
                when CALC_VTX_ADDR =>
                    -- Calculate vertex base address
                    -- Resize stride to 32 bits for multiplication
                    vertex_addr <= unsigned(vtx_buf_addr) + 
                                   resize(vertex_index * resize(unsigned(vtx_buf_stride), 32), 32);
                    
                    if attr_enable_r(0) = '1' then
                        state <= FETCH_POS_X;
                    elsif attr_enable_r(1) = '1' then
                        state <= FETCH_UV_U;
                    elsif attr_enable_r(2) = '1' then
                        state <= FETCH_COLOR;
                    else
                        state <= OUTPUT_VERTEX;
                    end if;
                
                -- Position fetch (3 floats)
                when FETCH_POS_X =>
                    mem_addr <= std_logic_vector(vertex_addr + unsigned(attr_pos_offset));
                    mem_size <= "10";  -- word
                    mem_en <= '1';
                    state <= WAIT_POS_X;
                
                when WAIT_POS_X =>
                    if mem_rd_valid = '1' then
                        pos_x <= mem_rd_data;
                        state <= FETCH_POS_Y;
                    end if;
                
                when FETCH_POS_Y =>
                    mem_addr <= std_logic_vector(vertex_addr + unsigned(attr_pos_offset) + 4);
                    mem_en <= '1';
                    state <= WAIT_POS_Y;
                
                when WAIT_POS_Y =>
                    if mem_rd_valid = '1' then
                        pos_y <= mem_rd_data;
                        state <= FETCH_POS_Z;
                    end if;
                
                when FETCH_POS_Z =>
                    mem_addr <= std_logic_vector(vertex_addr + unsigned(attr_pos_offset) + 8);
                    mem_en <= '1';
                    state <= WAIT_POS_Z;
                
                when WAIT_POS_Z =>
                    if mem_rd_valid = '1' then
                        pos_z <= mem_rd_data;
                        -- Next attribute
                        if attr_enable_r(1) = '1' then
                            state <= FETCH_UV_U;
                        elsif attr_enable_r(2) = '1' then
                            state <= FETCH_COLOR;
                        else
                            state <= OUTPUT_VERTEX;
                        end if;
                    end if;
                
                -- UV fetch (2 floats)
                when FETCH_UV_U =>
                    mem_addr <= std_logic_vector(vertex_addr + unsigned(attr_uv_offset));
                    mem_en <= '1';
                    state <= WAIT_UV_U;
                
                when WAIT_UV_U =>
                    if mem_rd_valid = '1' then
                        uv_u <= mem_rd_data;
                        state <= FETCH_UV_V;
                    end if;
                
                when FETCH_UV_V =>
                    mem_addr <= std_logic_vector(vertex_addr + unsigned(attr_uv_offset) + 4);
                    mem_en <= '1';
                    state <= WAIT_UV_V;
                
                when WAIT_UV_V =>
                    if mem_rd_valid = '1' then
                        uv_v <= mem_rd_data;
                        if attr_enable_r(2) = '1' then
                            state <= FETCH_COLOR;
                        else
                            state <= OUTPUT_VERTEX;
                        end if;
                    end if;
                
                -- Color fetch (1 word, RGBA8)
                when FETCH_COLOR =>
                    mem_addr <= std_logic_vector(vertex_addr + unsigned(attr_color_off));
                    mem_en <= '1';
                    state <= WAIT_COLOR;
                
                when WAIT_COLOR =>
                    if mem_rd_valid = '1' then
                        color <= mem_rd_data;
                        state <= OUTPUT_VERTEX;
                    end if;
                
                ---------------------------------------------------------------
                -- Output vertex
                ---------------------------------------------------------------
                when OUTPUT_VERTEX =>
                    vtx_valid <= '1';
                    
                    if vtx_ready = '1' then
                        vertices_done <= vertices_done + 1;
                        current_idx <= current_idx + 1;
                        
                        -- Check if done
                        if vertices_done + 1 >= draw_count_r then
                            state <= IDLE;
                        else
                            -- Fetch next vertex
                            if draw_indexed_r = '1' then
                                state <= FETCH_INDEX;
                            else
                                vertex_index <= vertex_index + 1;
                                state <= CALC_VTX_ADDR;
                            end if;
                        end if;
                    end if;
                
                when others =>
                    state <= IDLE;
            end case;
        end if;
    end process;

end architecture rtl;
