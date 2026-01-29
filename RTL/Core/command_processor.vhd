-------------------------------------------------------------------------------
-- command_processor.vhd
-- GPU Command Processor
-- Reads commands from CPU and dispatches work to GPU units
--
-- Command Buffer Format:
--   Word 0: Command header (opcode, flags, count)
--   Word 1+: Command-specific payload
--
-- Supported Commands:
--   0x01: SET_STATE       - Write render state register
--   0x02: CLEAR           - Clear color/depth buffer
--   0x03: DRAW_TRIANGLES  - Draw indexed triangles
--   0x04: SET_TEXTURE     - Configure texture unit
--   0x05: RUN_SHADER      - Launch shader program
--   0x06: FENCE           - Memory fence / sync point
--   0x07: NOP             - No operation
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity command_processor is
    generic (
        CMD_FIFO_DEPTH : integer := 16
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- CPU interface (write commands)
        cmd_wr_valid    : in  std_logic;
        cmd_wr_ready    : out std_logic;
        cmd_wr_data     : in  std_logic_vector(31 downto 0);
        
        -- Status registers (readable by CPU)
        status          : out std_logic_vector(31 downto 0);
        fence_value     : out std_logic_vector(31 downto 0);
        
        -- Render state output
        state_wr_en     : out std_logic;
        state_wr_addr   : out std_logic_vector(7 downto 0);
        state_wr_data   : out std_logic_vector(31 downto 0);
        
        -- Clear commands
        clear_valid     : out std_logic;
        clear_ready     : in  std_logic;
        clear_color     : out std_logic_vector(31 downto 0);
        clear_depth     : out std_logic_vector(23 downto 0);
        clear_flags     : out std_logic_vector(1 downto 0);  -- [0]=color, [1]=depth
        
        -- Triangle draw commands
        draw_valid      : out std_logic;
        draw_ready      : in  std_logic;
        draw_start_idx  : out std_logic_vector(31 downto 0);
        draw_count      : out std_logic_vector(31 downto 0);
        draw_done       : in  std_logic;
        
        -- Texture configuration
        tex_cfg_valid   : out std_logic;
        tex_cfg_unit    : out std_logic_vector(3 downto 0);
        tex_cfg_addr    : out std_logic_vector(31 downto 0);
        tex_cfg_width   : out std_logic_vector(15 downto 0);
        tex_cfg_height  : out std_logic_vector(15 downto 0);
        tex_cfg_format  : out std_logic_vector(3 downto 0);
        
        -- Shader launch
        shader_valid    : out std_logic;
        shader_ready    : in  std_logic;
        shader_pc       : out std_logic_vector(31 downto 0);
        shader_count    : out std_logic_vector(31 downto 0);
        shader_done     : in  std_logic;
        
        -- Memory interface for reading command buffer
        mem_rd_addr     : out std_logic_vector(31 downto 0);
        mem_rd_en       : out std_logic;
        mem_rd_data     : in  std_logic_vector(31 downto 0);
        mem_rd_valid    : in  std_logic
    );
end entity command_processor;

architecture rtl of command_processor is

    -- Command opcodes
    constant CMD_NOP            : std_logic_vector(7 downto 0) := x"00";
    constant CMD_SET_STATE      : std_logic_vector(7 downto 0) := x"01";
    constant CMD_CLEAR          : std_logic_vector(7 downto 0) := x"02";
    constant CMD_DRAW_TRIANGLES : std_logic_vector(7 downto 0) := x"03";
    constant CMD_SET_TEXTURE    : std_logic_vector(7 downto 0) := x"04";
    constant CMD_RUN_SHADER     : std_logic_vector(7 downto 0) := x"05";
    constant CMD_FENCE          : std_logic_vector(7 downto 0) := x"06";
    
    -- State machine
    type state_t is (
        IDLE,
        DECODE,
        -- SET_STATE
        STATE_WRITE,
        -- CLEAR
        CLEAR_EXEC,
        CLEAR_WAIT,
        -- DRAW
        DRAW_EXEC,
        DRAW_WAIT,
        -- TEXTURE
        TEX_READ_ADDR,
        TEX_READ_SIZE,
        TEX_EXEC,
        -- SHADER
        SHADER_READ_COUNT,
        SHADER_EXEC,
        SHADER_WAIT,
        -- FENCE
        FENCE_EXEC
    );
    signal state : state_t := IDLE;
    
    -- Command FIFO
    type cmd_fifo_t is array (0 to CMD_FIFO_DEPTH-1) of std_logic_vector(31 downto 0);
    signal cmd_fifo : cmd_fifo_t;
    signal fifo_wr_ptr, fifo_rd_ptr : unsigned(3 downto 0) := (others => '0');
    signal fifo_count : unsigned(4 downto 0) := (others => '0');
    
    -- Current command
    signal current_cmd : std_logic_vector(31 downto 0);
    signal cmd_opcode : std_logic_vector(7 downto 0);
    signal cmd_param : std_logic_vector(23 downto 0);
    
    -- Latched parameters
    signal lat_addr : std_logic_vector(31 downto 0);
    signal lat_count : std_logic_vector(31 downto 0);
    
    -- Fence counter
    signal fence_counter : unsigned(31 downto 0) := (others => '0');
    
    -- FIFO consume signal (set by main FSM when reading from FIFO)
    signal fifo_consume : std_logic := '0';
    
    -- Status
    signal busy : std_logic := '0';
    signal error : std_logic := '0';
    signal cmd_count : unsigned(31 downto 0) := (others => '0');

begin

    -- FIFO control
    cmd_wr_ready <= '1' when fifo_count < CMD_FIFO_DEPTH else '0';
    
    -- Parse command
    cmd_opcode <= current_cmd(7 downto 0);
    cmd_param <= current_cmd(31 downto 8);
    
    -- Status register
    status <= error & "000000" & busy & std_logic_vector(cmd_count(23 downto 0));
    fence_value <= std_logic_vector(fence_counter);
    
    ---------------------------------------------------------------------------
    -- FIFO Management Process
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable delta : integer;
    begin
        if rst_n = '0' then
            fifo_wr_ptr <= (others => '0');
            fifo_count <= (others => '0');
        elsif rising_edge(clk) then
            delta := 0;
            
            -- Only write to FIFO when NOT in IDLE (busy) or already have items
            -- This prevents corrupting FIFO during direct passthrough
            if cmd_wr_valid = '1' and fifo_count < CMD_FIFO_DEPTH then
                if state /= IDLE or fifo_count > 0 then
                    cmd_fifo(to_integer(fifo_wr_ptr)) <= cmd_wr_data;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                    delta := delta + 1;
                end if;
            end if;
            
            -- Consume from FIFO (signaled by main FSM)
            if fifo_consume = '1' then
                delta := delta - 1;
            end if;
            
            -- Update count
            if delta > 0 then
                fifo_count <= fifo_count + 1;
            elsif delta < 0 and fifo_count > 0 then
                fifo_count <= fifo_count - 1;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Main Command Processing State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state <= IDLE;
            fifo_rd_ptr <= (others => '0');
            current_cmd <= (others => '0');
            busy <= '0';
            error <= '0';
            cmd_count <= (others => '0');
            fence_counter <= (others => '0');
            
            state_wr_en <= '0';
            clear_valid <= '0';
            draw_valid <= '0';
            tex_cfg_valid <= '0';
            shader_valid <= '0';
            mem_rd_en <= '0';
            fifo_consume <= '0';
            
        elsif rising_edge(clk) then
            -- Default: deassert single-cycle signals
            state_wr_en <= '0';
            tex_cfg_valid <= '0';
            mem_rd_en <= '0';
            fifo_consume <= '0';
            
            case state is
                ---------------------------------------------------------------
                when IDLE =>
                    busy <= '0';
                    
                    -- Check for command
                    if fifo_count > 0 then
                        current_cmd <= cmd_fifo(to_integer(fifo_rd_ptr));
                        fifo_rd_ptr <= fifo_rd_ptr + 1;
                        fifo_consume <= '1';  -- Signal FIFO consumption
                        state <= DECODE;
                        busy <= '1';
                    elsif cmd_wr_valid = '1' then
                        -- Direct command without FIFO delay
                        current_cmd <= cmd_wr_data;
                        state <= DECODE;
                        busy <= '1';
                    end if;
                
                ---------------------------------------------------------------
                when DECODE =>
                    cmd_count <= cmd_count + 1;
                    
                    case cmd_opcode is
                        when CMD_NOP =>
                            state <= IDLE;
                        
                        when CMD_SET_STATE =>
                            -- param[7:0] = register offset, param[23:8] unused
                            -- Next word is the value
                            state <= STATE_WRITE;
                        
                        when CMD_CLEAR =>
                            -- param[0] = clear color, param[1] = clear depth
                            clear_flags <= cmd_param(1 downto 0);
                            state <= CLEAR_EXEC;
                        
                        when CMD_DRAW_TRIANGLES =>
                            -- param = start index, next word = count
                            lat_addr <= x"000000" & cmd_param(7 downto 0);
                            draw_start_idx <= x"000000" & cmd_param(7 downto 0);
                            state <= DRAW_EXEC;
                        
                        when CMD_SET_TEXTURE =>
                            -- param[3:0] = texture unit
                            tex_cfg_unit <= cmd_param(3 downto 0);
                            state <= TEX_READ_ADDR;
                        
                        when CMD_RUN_SHADER =>
                            -- param[23:0] = shader PC (byte address)
                            shader_pc <= x"00" & cmd_param;
                            state <= SHADER_READ_COUNT;
                        
                        when CMD_FENCE =>
                            state <= FENCE_EXEC;
                        
                        when others =>
                            error <= '1';
                            state <= IDLE;
                    end case;
                
                ---------------------------------------------------------------
                -- SET_STATE: Write render state register
                ---------------------------------------------------------------
                when STATE_WRITE =>
                    if fifo_count > 0 then
                        state_wr_en <= '1';
                        state_wr_addr <= cmd_param(7 downto 0);
                        state_wr_data <= cmd_fifo(to_integer(fifo_rd_ptr));
                        fifo_rd_ptr <= fifo_rd_ptr + 1;
                        fifo_consume <= '1';
                        state <= IDLE;
                    elsif cmd_wr_valid = '1' then
                        state_wr_en <= '1';
                        state_wr_addr <= cmd_param(7 downto 0);
                        state_wr_data <= cmd_wr_data;
                        state <= IDLE;
                    end if;
                
                ---------------------------------------------------------------
                -- CLEAR: Clear framebuffer
                ---------------------------------------------------------------
                when CLEAR_EXEC =>
                    -- Read clear values from next words if needed
                    clear_color <= x"00000000";  -- Could read from command
                    clear_depth <= x"FFFFFF";
                    clear_valid <= '1';
                    state <= CLEAR_WAIT;
                
                when CLEAR_WAIT =>
                    if clear_ready = '1' then
                        clear_valid <= '0';
                        state <= IDLE;
                    end if;
                
                ---------------------------------------------------------------
                -- DRAW_TRIANGLES: Draw primitives
                ---------------------------------------------------------------
                when DRAW_EXEC =>
                    -- Read triangle count from next word
                    if fifo_count > 0 then
                        draw_count <= cmd_fifo(to_integer(fifo_rd_ptr));
                        fifo_rd_ptr <= fifo_rd_ptr + 1;
                        fifo_consume <= '1';
                        draw_valid <= '1';
                        state <= DRAW_WAIT;
                    elsif cmd_wr_valid = '1' then
                        draw_count <= cmd_wr_data;
                        draw_valid <= '1';
                        state <= DRAW_WAIT;
                    end if;
                
                when DRAW_WAIT =>
                    if draw_ready = '1' then
                        draw_valid <= '0';
                    end if;
                    if draw_done = '1' then
                        state <= IDLE;
                    end if;
                
                ---------------------------------------------------------------
                -- SET_TEXTURE: Configure texture unit
                ---------------------------------------------------------------
                when TEX_READ_ADDR =>
                    if fifo_count > 0 then
                        tex_cfg_addr <= cmd_fifo(to_integer(fifo_rd_ptr));
                        fifo_rd_ptr <= fifo_rd_ptr + 1;
                        fifo_consume <= '1';
                        state <= TEX_READ_SIZE;
                    elsif cmd_wr_valid = '1' then
                        tex_cfg_addr <= cmd_wr_data;
                        state <= TEX_READ_SIZE;
                    end if;
                
                when TEX_READ_SIZE =>
                    if fifo_count > 0 then
                        tex_cfg_width <= cmd_fifo(to_integer(fifo_rd_ptr))(15 downto 0);
                        tex_cfg_height <= cmd_fifo(to_integer(fifo_rd_ptr))(31 downto 16);
                        fifo_rd_ptr <= fifo_rd_ptr + 1;
                        fifo_consume <= '1';
                        state <= TEX_EXEC;
                    elsif cmd_wr_valid = '1' then
                        tex_cfg_width <= cmd_wr_data(15 downto 0);
                        tex_cfg_height <= cmd_wr_data(31 downto 16);
                        state <= TEX_EXEC;
                    end if;
                
                when TEX_EXEC =>
                    -- Read format from next word
                    if fifo_count > 0 then
                        tex_cfg_format <= cmd_fifo(to_integer(fifo_rd_ptr))(3 downto 0);
                        fifo_rd_ptr <= fifo_rd_ptr + 1;
                        fifo_consume <= '1';
                        tex_cfg_valid <= '1';
                        state <= IDLE;
                    elsif cmd_wr_valid = '1' then
                        tex_cfg_format <= cmd_wr_data(3 downto 0);
                        tex_cfg_valid <= '1';
                        state <= IDLE;
                    end if;
                
                ---------------------------------------------------------------
                -- RUN_SHADER: Launch shader program
                ---------------------------------------------------------------
                when SHADER_READ_COUNT =>
                    if fifo_count > 0 then
                        shader_count <= cmd_fifo(to_integer(fifo_rd_ptr));
                        fifo_rd_ptr <= fifo_rd_ptr + 1;
                        fifo_consume <= '1';
                        shader_valid <= '1';
                        state <= SHADER_EXEC;
                    elsif cmd_wr_valid = '1' then
                        shader_count <= cmd_wr_data;
                        shader_valid <= '1';
                        state <= SHADER_EXEC;
                    end if;
                
                when SHADER_EXEC =>
                    if shader_ready = '1' then
                        shader_valid <= '0';
                        state <= SHADER_WAIT;
                    end if;
                
                when SHADER_WAIT =>
                    if shader_done = '1' then
                        state <= IDLE;
                    end if;
                
                ---------------------------------------------------------------
                -- FENCE: Memory barrier / sync point
                ---------------------------------------------------------------
                when FENCE_EXEC =>
                    fence_counter <= fence_counter + 1;
                    state <= IDLE;
                
            end case;
        end if;
    end process;

end architecture rtl;
