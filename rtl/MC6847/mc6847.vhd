library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity mc6847 is
    generic
        (
            T1_VARIANT   : boolean := false;
            CVBS_NOT_VGA : boolean := true);
    port
        (
            clk            : in  std_logic;
            clk_ena        : in  std_logic;
            reset          : in  std_logic;
            da0            : out std_logic;
            videoaddr      : out std_logic_vector (12 downto 0);
            dd             : in  std_logic_vector(7 downto 0);
            hs_n           : out std_logic;
            fs_n           : out std_logic;
            an_g           : in  std_logic;
            an_s           : in  std_logic;
            intn_ext       : in  std_logic;
            gm             : in  std_logic_vector(2 downto 0);
            css            : in  std_logic;
            inv            : in  std_logic;
            red            : out std_logic_vector(7 downto 0);
            green          : out std_logic_vector(7 downto 0);
            blue           : out std_logic_vector(7 downto 0);
            hsync          : out std_logic;
            vsync          : out std_logic;
            hblank         : out std_logic;
            vblank         : out std_logic;
            artifact_en    : in  std_logic;
            artifact_set   : in  std_logic;
            artifact_phase : in  std_logic;
            cvbs           : out std_logic_vector(7 downto 0);
            black_backgnd  : in  std_logic;
            -- 15 kHz: '1' shows the border (green/buff in graphics modes, black
            -- otherwise) and blanks only where the 6847 blanks; '0' shows the
            -- 256x192 picture only
            border         : in  std_logic := '1';
            char_a         : out std_logic_vector(11 downto 0);
            char_d_o       : in std_logic_vector(7 downto 0);
            pixel_clock    : out std_logic
            );
end mc6847;

architecture SYN of mc6847 is

    constant BUILD_DEBUG    : boolean                      := false;
    constant DEBUG_AN_G     : std_logic                    := '1';
    constant DEBUG_AN_S     : std_logic                    := '1';
    constant DEBUG_INTN_EXT : std_logic                    := '1';
    constant DEBUG_GM       : std_logic_vector(2 downto 0) := "111";
    constant DEBUG_CSS      : std_logic                    := '1';
    constant DEBUG_INV      : std_logic                    := '0';

    -- VGA (scan-doubled) timing: AtomGodilVideo's, unchanged. This core runs
    -- the 15 kHz (CVBS) side (CVBS_NOT_VGA), so these only drive PROC_VGA.
    -- H_TOTAL_PER_LINE must be divisible by 16 so that the pixel phase is the
    -- same on every line.
    constant H_FRONT_PORCH    : integer := 8;
    constant H_HORIZ_SYNC     : integer := H_FRONT_PORCH + 48;
    constant H_BACK_PORCH     : integer := H_HORIZ_SYNC + 24;
    constant H_LEFT_BORDER    : integer := H_BACK_PORCH + 32;
    constant H_VIDEO          : integer := H_LEFT_BORDER + 256;
    constant H_RIGHT_BORDER   : integer := H_VIDEO + 31;
    constant H_TOTAL_PER_LINE : integer := H_RIGHT_BORDER;

    -- 15 kHz timing: the MC6847 datasheet (Motorola 1984, refs/docs/chips).
    -- One count is one pixel, half a 3.58 MHz period (1/f): the datasheet's
    -- times doubled. Counted from the leading edge of horizontal sync:
    --   sync 35 (tHBNK 42 - front porch 7 - back porch 17.5 = 17.5 x 1/f),
    --   back porch 35 (17.5), left border 59 (29.5), picture 256 (128),
    --   right border 56 (28), front porch 14 (7): 455 (227.5 x 1/f), 63.56 us.
    constant C_HS_END    : integer := 35;
    constant C_BORDER_L  : integer := C_HS_END + 35;        --  70
    constant C_PIC       : integer := C_BORDER_L + 59;      -- 129
    constant C_BORDER_R  : integer := C_PIC + 256;          -- 385
    constant C_BLANK     : integer := C_BORDER_R + 56;      -- 441
    constant C_LINE      : integer := C_BLANK + 14;         -- 455
    -- The fetch runs ahead of the output: a byte is addressed, read, latched
    -- into the shifter and the pixel registered at the output, so the first
    -- pixel comes out C_PIPE counts after the fetch window opens (measured in
    -- the Verilator sim with --trace-video). The address counter starts 8
    -- counts before the window, as AtomGodilVideo's does.
    constant C_PIPE      : integer := 2;
    constant C_FETCH     : integer := C_PIC - C_PIPE;
    constant C_FETCH_RST : integer := C_FETCH - 8;
    -- Vertical, in lines, counted from the first picture line (datasheet
    -- Figure 13): picture 192, bottom border 26, vertical retrace 6
    -- (3 blank lines, then 3 of vertical sync), vertical blanking 13, top
    -- border 25: 262 lines, 59.94 Hz. FS goes low at the end of the picture
    -- and high at the end of vertical sync: 32 lines (Figure 8, tWFS).
    constant V_PIC_END   : integer := 192;
    constant V_BORDER_END: integer := V_PIC_END + 26;       -- 218
    constant V_VS        : integer := V_BORDER_END + 3;     -- 221
    constant V_VS_END    : integer := V_VS + 3;             -- 224: FS rises
    constant V_BORDER_T  : integer := V_VS_END + 13;        -- 237
    constant V_LAST      : integer := V_BORDER_T + 25 - 1;  -- 261

    -- internal version of control ports
    signal an_g_s     : std_logic;
    signal an_s_s     : std_logic;
    signal intn_ext_s : std_logic;
    signal gm_s       : std_logic_vector(2 downto 0);
    signal css_s      : std_logic;
    signal inv_s      : std_logic;

    -- VGA signals
	signal vga_clk_ena					: std_logic;
    signal vga_hsync        : std_logic;
    signal vga_vsync        : std_logic;
    signal vga_hblank       : std_logic;
    signal vga_vblank       : std_logic;
    signal vga_linebuf_addr : std_logic_vector(8 downto 0);
    signal vga_char_d_o     : std_logic_vector(7 downto 0);
    signal vga_hborder      : std_logic;
    signal vga_vborder      : std_logic;

    -- CVBS signals
    signal cvbs_clk_ena      : std_logic;  -- PAL/NTSC*2
    signal cvbs_hsync        : std_logic;
    signal cvbs_vsync        : std_logic;
    signal cvbs_hblank       : std_logic;
    signal cvbs_vblank       : std_logic;
    signal cvbs_hborder      : std_logic;
    signal cvbs_vborder      : std_logic;
    signal cvbs_linebuf_we   : std_logic;
    signal cvbs_linebuf_addr : std_logic_vector(8 downto 0);
    -- where PROC_OUTPUT's next pixel is (set by PROC_CVBS): in horizontal /
    -- vertical sync, in the picture, in the visible area (picture + border)
    signal o_hs, o_vs, o_hpic, o_vpic, o_hvis, o_vvis : std_logic;

    signal active_h_start : std_logic := '0';
    signal an_s_r         : std_logic;
    signal inv_r          : std_logic;
    signal intn_ext_r     : std_logic;
    signal dd_r           : std_logic_vector(7 downto 0);
    signal pixel_char_d_o : std_logic_vector(7 downto 0);
    signal cvbs_char_d_o  : std_logic_vector(7 downto 0);  -- CVBS char_d_o out

    alias hs_int   : std_logic is cvbs_hblank;
    signal fs_int  : std_logic;
    signal da0_int : std_logic_vector(4 downto 0);

    -- character rom signals
    signal cvbs_linebuf_we_r    : std_logic;
    signal cvbs_linebuf_addr_r  : std_logic_vector(8 downto 0);
    signal cvbs_linebuf_we_rr   : std_logic;
    signal cvbs_linebuf_addr_rr : std_logic_vector(8 downto 0);

    signal lookup               : std_logic_vector(5 downto 0);
    signal tripletaddr          : std_logic_vector(7 downto 0);
    signal tripletcnt           : std_logic_vector(3 downto 0);
    -----------------------------------------------------------------------
    type   vram_type is array (511 downto 0) of std_logic_vector (7 downto 0);
    signal VRAM                 : vram_type := (511 downto 0 => X"FF");
--    attribute RAM_STYLE         : string;
--    attribute RAM_STYLE of VRAM : signal is "BLOCK";
    ------------------------------------------------------------------------

    -- used by both CVBS and VGA
    shared variable v_count : std_logic_vector(8 downto 0);
    shared variable row_v   : std_logic_vector(3 downto 0);

    procedure map_palette (vga_char_d_o : in  std_logic_vector(7 downto 0);
                           r            : out std_logic_vector(7 downto 0);
                           g            : out std_logic_vector(7 downto 0);
                           b            : out std_logic_vector(7 downto 0)) is

        type     pal_entry_t is array (0 to 2) of std_logic_vector(1 downto 0);
        type     pal_a is array (0 to 7) of pal_entry_t;
        constant pal : pal_a :=
            (
                0 => (0 => "00", 1 => "11", 2=>"00"),  -- green
                1 => (0 => "11", 1 => "11", 2=>"00"),  -- yellow
                2 => (0 => "00", 1 => "00", 2=>"11"),  -- blue
                3 => (0 => "11", 1 => "00", 2=>"00"),  -- red
                4 => (0 => "11", 1 => "11", 2=>"11"),  -- white
                5 => (0 => "00", 1 => "11", 2=>"11"),  -- cyan
                6 => (0 => "11", 1 => "00", 2=>"11"),  -- magenta
                7 => (0 => "11", 1 => "10", 2=>"00")   -- orange
                --others => (others => (others => '0'))
                );
        alias css_v  : std_logic is vga_char_d_o(6);
        alias an_g_v : std_logic is vga_char_d_o(5);
        alias an_s_v : std_logic is vga_char_d_o(4);
        alias luma   : std_logic is vga_char_d_o(3);
        alias chroma : std_logic_vector(2 downto 0) is vga_char_d_o(2 downto 0);
        

    begin
        if luma = '1' then
            r := pal(to_integer(unsigned(chroma)))(0) & "000000";
            g := pal(to_integer(unsigned(chroma)))(1) & "000000";
            b := pal(to_integer(unsigned(chroma)))(2) & "000000";
        else
            -- not quite black in alpha mode
            if black_backgnd = '0' and an_g_v = '0' and an_s_v = '0' then
                -- dark green/orange
                r := '0' & css_v & "000000";
                g := "01000000";
            else
                r := (others => '0');
                g := (others => '0');
            end if;
            b := (others => '0');
        end if;
    end procedure;
    
begin

    -- assign control inputs for debug/release build
    an_g_s     <= DEBUG_AN_G     when BUILD_DEBUG else an_g;
    an_s_s     <= DEBUG_AN_S     when BUILD_DEBUG else an_s;
    intn_ext_s <= DEBUG_INTN_EXT when BUILD_DEBUG else intn_ext;
    gm_s       <= DEBUG_GM       when BUILD_DEBUG else gm;
    css_s      <= DEBUG_CSS      when BUILD_DEBUG else css;
    inv_s      <= DEBUG_INV      when BUILD_DEBUG else inv;

    -- generate the clocks
    PROC_CLOCKS : process (clk, reset)
        variable toggle : std_logic := '0';
    begin
        if reset = '1' then
            toggle       := '0';
            cvbs_clk_ena <= '0';
        elsif rising_edge(clk) then
            cvbs_clk_ena <= '0';        -- default
            if clk_ena = '1' then
                cvbs_clk_ena <= toggle;
                toggle       := not toggle;
            end if;
      vga_clk_ena <= clk_ena;
        end if;
    end process PROC_CLOCKS;

    -- generate horizontal timing for VGA
    -- generate line buffer address for reading VGA char_d_o
    PROC_VGA : process (clk, reset)
        variable h_count        : integer range 0 to H_TOTAL_PER_LINE;
        variable active_h_count : std_logic_vector(7 downto 0);
        variable vga_vblank_r   : std_logic;
    begin
        if reset = '1' then
            h_count    := 0;
            vga_hsync  <= '1';
            vga_vsync  <= '1';
            vga_hblank <= '0';
            
        elsif rising_edge (clk) and vga_clk_ena = '1' then

            -- start hsync when cvbs comes out of vblank
            if vga_vblank_r = '1' and vga_vblank = '0' then
                h_count := 0;
            else
                if h_count = H_TOTAL_PER_LINE then
                    h_count     := 0;
                    vga_hborder <= '0';
                else
                    h_count := h_count + 1;
                end if;

                if h_count = H_FRONT_PORCH then
                    vga_hsync <= '0';
                elsif h_count = H_HORIZ_SYNC then
                    vga_hsync <= '1';
                elsif h_count = H_BACK_PORCH then
                    vga_hborder <= '1';
                elsif h_count = H_LEFT_BORDER+1 then
                    vga_hblank <= '0';
                elsif h_count = H_VIDEO+1 then
                    vga_hblank <= '1';
                elsif h_count = H_RIGHT_BORDER then
                    vga_hborder <= '0';
                end if;

                if h_count = H_LEFT_BORDER then
                    active_h_count := (others => '1');
                else
                    active_h_count := std_logic_vector(unsigned(active_h_count) + 1);
                end if;

            end if;

            -- vertical syncs, blanks are the same
            vga_vsync        <= cvbs_vsync;
            -- generate linebuffer address
            -- - alternate every 2nd line
            vga_linebuf_addr <= (not v_count(0)) & active_h_count;
            vga_vblank_r     := vga_vblank;
        end if;
    end process;

    -- 15 kHz timing (constants above) and the fetch for the line buffer.
    -- h_count 0 is the leading edge of horizontal sync. The fetch window
    -- (cvbs_hblank low) opens at C_FETCH, C_PIPE counts before its first
    -- pixel leaves PROC_OUTPUT at C_PIC. The o_* flags say where the pixel
    -- leaving PROC_OUTPUT is on the screen: they are set one count early,
    -- because PROC_OUTPUT registers them again with the pixel.
    PROC_CVBS : process (clk, reset)
        variable h_count        : integer range 0 to C_LINE - 1;
        variable hpos           : integer range 0 to C_LINE - 1;
        variable v              : integer range 0 to 511;
        variable active_h_count : std_logic_vector(7 downto 0);
        variable cvbs_hblank_r  : std_logic := '0';
        variable videoaddr_base : std_logic_vector(12 downto 0);

    begin
        if reset = '1' then

            h_count        := C_LINE - 1;
            v_count        := std_logic_vector(to_unsigned(V_LAST, v_count'length));
            active_h_count := (others => '0');
            active_h_start <= '0';
            cvbs_hsync     <= '1';
            cvbs_vsync     <= '1';
            cvbs_hblank    <= '1';
            cvbs_vblank    <= '1';
            cvbs_vborder   <= '0';
            vga_vblank     <= '1';
            fs_int         <= '1';
            o_hs           <= '0';
            o_vs           <= '0';
            o_hpic         <= '0';
            o_vpic         <= '0';
            o_hvis         <= '0';
            o_vvis         <= '0';
            da0_int        <= (others => '0');
            cvbs_hblank_r  := '0';
            row_v          := (others => '0');

        elsif rising_edge (clk) and cvbs_clk_ena = '1' then

            active_h_start <= '0';
            if h_count = C_LINE - 1 then
                h_count := 0;
                if v_count = V_LAST then
                    v_count := (others => '0');
                else
                    v_count := v_count + 1;
                end if;
                v := to_integer(unsigned(v_count));

                -- VGA vblank is 1 line behind CVBS
                -- - because we need to fill the line buffer
                vga_vblank <= cvbs_vblank;

                -- vertical events at the start of line v
                if v = 0 then
                    cvbs_vblank    <= '0';
                    row_v          := (others => '0');
                    videoaddr_base := (others => '0');
                    tripletaddr    <= (others => '0');
                    tripletcnt     <= (others => '0');
                elsif v = V_PIC_END then
                    cvbs_vblank <= '1';
                    fs_int      <= '1';
                elsif v = V_VS then
                    cvbs_vsync <= '0';
                elsif v = V_VS_END then
                    cvbs_vsync <= '1';
                    fs_int     <= '0';
                else
                    -- the next picture line: video address and character row
                    if an_g_s = '0' then
                        if (row_v = 11) then
                            videoaddr_base := videoaddr_base + 32;
                        end if;
                    else
                        case gm is
                            when "000" | "001" =>
                                if (tripletcnt = 2) then
                                    videoaddr_base := videoaddr_base + 16;
                                end if;
                            when "010" =>
                                if (tripletcnt = 2) then
                                    videoaddr_base := videoaddr_base + 32;
                                end if;
                            when "011" =>
                                if (row_v(0) = '1') then
                                    videoaddr_base := videoaddr_base + 16;
                                end if;
                            when "100" =>
                                if (row_v(0) = '1') then
                                    videoaddr_base := videoaddr_base + 32;
                                end if;
                            when "101" =>
                                    videoaddr_base := videoaddr_base + 16;
                            when "110" | "111" =>
                                    videoaddr_base := videoaddr_base + 32;
                            when others =>
                                null;
                        end case;
                    end if;
                    if tripletcnt = 2 then  -- mode 1,1a,2a
                        tripletcnt  <= (others => '0');
                        tripletaddr <= tripletaddr + 1;
                    else
                        tripletcnt <= tripletcnt + 1;
                    end if;
                    if row_v = 11 then
                        row_v := (others => '0');
                    else
                        row_v := row_v + 1;
                    end if;
                end if;

                -- where the lines of this field are on the screen
                if v < V_PIC_END then o_vpic <= '1'; else o_vpic <= '0'; end if;
                if v < V_BORDER_END or v >= V_BORDER_T then o_vvis <= '1'; else o_vvis <= '0'; end if;
                if v >= V_VS and v < V_VS_END then o_vs <= '1'; else o_vs <= '0'; end if;
                if v >= V_PIC_END and v < V_BORDER_END then cvbs_vborder <= '1';
                elsif v >= V_BORDER_T then cvbs_vborder <= '1';
                else cvbs_vborder <= '0'; end if;
            else
                h_count := h_count + 1;

                -- the fetch: the address counter starts 8 counts before the
                -- window and holds for the count the window opens on
                if h_count = C_FETCH_RST then
                    active_h_count := (others => '0');
                elsif h_count = C_FETCH then
                    cvbs_hblank    <= '0';
                elsif h_count = C_FETCH + 256 then
                    cvbs_hblank    <= '1';
                    active_h_count := active_h_count + 1;
                else
                    active_h_count := active_h_count + 1;
                end if;
            end if;

            -- The shifter's phase starts with the window, so every mode
            -- (8 or 16 pixels per byte) latches its first byte as the window
            -- opens, whatever the line length.
            if h_count = C_FETCH - 1 then
                active_h_start <= '1';
            end if;

            -- where the next count's pixel is on the screen
            if h_count = C_LINE - 1 then hpos := 0; else hpos := h_count + 1; end if;
            if hpos < C_HS_END then o_hs <= '1'; else o_hs <= '0'; end if;
            if hpos >= C_PIC and hpos < C_BORDER_R then o_hpic <= '1'; else o_hpic <= '0'; end if;
            if hpos >= C_BORDER_L and hpos < C_BLANK then o_hvis <= '1'; else o_hvis <= '0'; end if;
            if hpos < C_HS_END then cvbs_hsync <= '0'; else cvbs_hsync <= '1'; end if;

    -- generate character rom address
            char_a <= dd(7 downto 0) & row_v(3 downto 0);

            -- DA0 high during FS
            if cvbs_vblank = '1' then
                da0_int <= (others => '1');
            elsif cvbs_hblank = '1' then
                da0_int <= (others => '0');
            elsif cvbs_hblank_r = '1' and cvbs_hblank = '0' then
                da0_int <= "01000";
            else
                da0_int <= da0_int + 1;
            end if;

            cvbs_linebuf_addr    <= v_count(0) & active_h_count;
            -- pipeline writes to linebuf because char_d_o is delayed 1 clock as well!
            cvbs_linebuf_we_r    <= cvbs_linebuf_we;
            cvbs_linebuf_addr_r  <= cvbs_linebuf_addr;
            cvbs_linebuf_we_rr   <= cvbs_linebuf_we_r;
            cvbs_linebuf_addr_rr <= cvbs_linebuf_addr_r;
            cvbs_hblank_r        := cvbs_hblank;

            if an_g_s = '0' then
                lookup(4 downto 0) <= active_h_count(7 downto 3);
                videoaddr          <= videoaddr_base(12 downto 5) & lookup(4 downto 0);
            else
                case gm is              --lookupaddr
                    when "000" | "001" | "011" | "101" =>
                        lookup(3 downto 0) <= active_h_count(7 downto 4);
                        videoaddr          <= videoaddr_base(12 downto 4) & lookup(3 downto 0);
                    when "010" | "100" | "110" | "111" =>
                        lookup(4 downto 0) <= active_h_count(7 downto 3);
                        videoaddr          <= videoaddr_base(12 downto 5) & lookup(4 downto 0);
                    when others =>
                        null;
                end case;
            end if;
        end if;  -- cvbs_clk_ena
    end process;

    -- handle latching & shifting of character, graphics char_d_o
    process (clk, reset)
        variable count : std_logic_vector(3 downto 0) := (others => '0');
    begin
        if reset = '1' then
            count := (others => '0');
        elsif rising_edge(clk) and cvbs_clk_ena = '1' then
            if active_h_start = '1' then
                count := (others => '0');
            end if;
            if an_g_s = '0' then
                -- alpha-semi modes
                if count(2 downto 0) = 0 then
                    -- handle alpha-semi latching
                    an_s_r <= an_s_s;
                    inv_r  <= inv_s;
                    intn_ext_r  <= intn_ext_s;
                    if an_s_s = '0' then
                        dd_r <= char_d_o;                  -- alpha mode
                    else
                        -- store luma,chroma(2..0),luma,chroma(2..0)
                        if intn_ext_s = '0' then           -- semi-4
                            if row_v < 6 then
                                dd_r <= dd(3) & dd(6) & dd(5) & dd(4) &
                                        dd(2) & dd(6) & dd(5) & dd(4);
                            else
                                dd_r <= dd(1) & dd(6) & dd(5) & dd(4) &
                                        dd(0) & dd(6) & dd(5) & dd(4);
                            end if;
                        else            -- semi-6
                            if row_v < 4 then
                                dd_r <= dd(5) & css_s & dd(7) & dd(6) &
                                        dd(4) & css_s & dd(7) & dd(6);
                            elsif row_v < 8 then
                                dd_r <= dd(3) & css_s & dd(7) & dd(6) &
                                        dd(2) & css_s & dd(7) & dd(6);
                            else
                                dd_r <= dd(1) & css_s & dd(7) & dd(6) &
                                        dd(0) & css_s & dd(7) & dd(6);
                            end if;
                        end if;
                    end if;
                else
                    -- handle alpha-semi shifting
                    if an_s_r = '0' then
                        dd_r <= dd_r(dd_r'left-1 downto 0) & '0';  -- alpha mode
                    else
                        if count(1 downto 0) = 0 then
                            dd_r <= dd_r(dd_r'left-4 downto 0) & "0000";  -- semi mode
                        end if;
                    end if;
                end if;
            else
                -- graphics modes
                --if IN_SIMULATION then
                an_s_r <= '0';
                --end if;
                case gm_s is
                    when "000" | "001" | "011" | "101" =>  -- CG1/RG1/RG2/RG3
                        if count(3 downto 0) = 0 then
                            -- handle graphics latching
                            dd_r <= dd;
                        else
                            -- handle graphics shifting
                            if gm_s = "000" then
                                if count(1 downto 0) = 0 then
                                    dd_r <= dd_r(dd_r'left-2 downto 0) & "00";  -- CG1
                                end if;
                            else
                                if count(0) = '0' then
                                    dd_r <= dd_r(dd_r'left-1 downto 0) & '0';  -- RG1/RG2/RG3
                                end if;
                            end if;
                        end if;
                    when others =>      -- CG2/CG3/CG6/RG6
                        if count(2 downto 0) = 0 then
                            -- handle graphics latching
                            dd_r <= dd;
                        else
                            -- handle graphics shifting
                            if gm_s = "111" then
                                dd_r <= dd_r(dd_r'left-1 downto 0) & '0';  -- RG6
                            else
                                if count(0) = '0' then
                                    dd_r <= dd_r(dd_r'left-2 downto 0) & "00";  -- CG2/CG3/CG6
                                end if;
                            end if;
                        end if;
                end case;
            end if;
            count := count + 1;
        end if;
    end process;

    -- generate pixel char_d_o
    process (clk, reset)
        variable luma   : std_logic;
        variable chroma : std_logic_vector(2 downto 0);
    begin
        if reset = '1' then
        elsif rising_edge(clk) and cvbs_clk_ena = '1' then
            -- alpha/graphics mode
            if an_g_s = '0' then
                -- alphanumeric & semi-graphics mode
                luma := dd_r(dd_r'left);
                if an_s_r = '0' then
                    -- alphanumeric
                    if intn_ext_r = '0' then
                        -- internal rom
                        chroma := (others => css_s);
                        if inv_r = '1' then
                            luma := not luma;
                        end if;  -- normal/inverse
                    else
                        -- external ROM?!?
                    end if;  -- internal/external
                else
                    chroma := dd_r(dd_r'left-1 downto dd_r'left-3);
                end if;  -- alphanumeric/semi-graphics
            else
                -- graphics mode
                case gm_s is
                    when "000" =>                  -- CG1 64x64x4
                        luma   := '1';
                        chroma := css_s & dd_r(dd_r'left downto dd_r'left-1);
                    when "001" | "011" | "101" =>  -- RG1/2/3 128x64/96/192x2
                        luma   := dd_r(dd_r'left);
                        chroma := css_s & "00";    -- green/buff
                    when "010" | "100" | "110" =>  -- CG2/3/6 128x64/96/192x4
                        luma   := '1';
                        chroma := css_s & dd_r(dd_r'left downto dd_r'left-1);
                    when others =>                 -- RG6 256x192x2
                        luma   := dd_r(dd_r'left);
                        chroma := css_s & "00";    -- green/buff
                end case;
            end if;  -- alpha/graphics mode

            -- pack source char_d_o into line buffer
            -- - palette lookup on output
            pixel_char_d_o <= '0' & css_s & an_g_s & an_s_r & luma & chroma;

        end if;
    end process;

    -- only write to the linebuffer during active display
    cvbs_linebuf_we <= not (cvbs_vblank or cvbs_hblank);

    cvbs <= '0' & cvbs_vsync & "000000" when cvbs_vblank = '1' else
            '0' & cvbs_hsync & "000000" when cvbs_hblank = '1' else
            cvbs_char_d_o;

    -- assign outputs

    hs_n <= not hs_int;
    fs_n <= not fs_int;
    da0  <= da0_int(4) when (gm_s = "001" or gm_s = "011" or gm_s = "101") else
            da0_int(3);

    -- map the palette to the pixel char_d_o
    -- -  we do that at the output so we can use a 
    --    higher colour-resolution palette
    --    without using memory in the line buffer
    PROC_OUTPUT : process (clk)
        variable r     : std_logic_vector(red'range);
        variable g     : std_logic_vector(green'range);
        variable b     : std_logic_vector(blue'range);
        -- for artifacting testing only
        variable p_in  : std_logic_vector(vga_char_d_o'range);
        variable p_out : std_logic_vector(vga_char_d_o'range);
        variable count : std_logic := '0';
    begin
        if reset = '1' then
            count := '0';
        elsif rising_edge(clk) then
            if CVBS_NOT_VGA then
                -- the pixel, its sync and its blanking leave together
                if cvbs_clk_ena = '1' then
                    if o_hpic = '1' and o_vpic = '1' then
                        map_palette (pixel_char_d_o, r, g, b);
                    elsif border = '1' and o_hvis = '1' and o_vvis = '1' and an_g_s = '1' then
                        -- graphics modes: the border is green or buff (CSS)
                        map_palette ("00001" & css_s & "00", r, g, b);
                    else
                        r := (others => '0');
                        g := (others => '0');
                        b := (others => '0');
                    end if;
                    red    <= r;
                    green  <= g;
                    blue   <= b;
                    hsync  <= not o_hs;
                    vsync  <= not o_vs;
                    if border = '1' then
                        hblank <= not o_hvis;
                        vblank <= not o_vvis;
                    else
                        hblank <= not o_hpic;
                        vblank <= not o_vpic;
                    end if;
                end if;
            else
                if clk_ena = '1' then
                    if vga_hblank = '1' then
                        count := '0';
                        p_in  := (others => '0');
                    end if;
                    if vga_hblank = '0' and vga_vblank = '0' then
                        -- artifacting test only --
                        if artifact_en = '1' and an_g_s = '1' and gm_s = "111" then
                            if count /= '0' then
                                p_out(p_out'left downto 4) := vga_char_d_o(p_out'left downto 4);
                                if p_in(3) = '0' and vga_char_d_o(3) = '0' then
                                    p_out(3 downto 0) := "0000";
                                elsif p_in(3) = '1' and vga_char_d_o(3) = '1' then
                                    p_out(3 downto 0) := "1100";
                                elsif p_in(3) = '0' and vga_char_d_o(3) = '1' then
                                    p_out(3 downto 0) := "1011";  -- red
                                    --p_out(3 downto 0) := "1101";  -- cyan
                                else
                                    p_out(3 downto 0) := "1010";  -- blue
                                    --p_out(3 downto 0) := "1111";  -- orange
                                end if;
                            end if;
                            map_palette (p_out, r, g, b);
                            p_in := vga_char_d_o;
                        else
                            map_palette (vga_char_d_o, r, g, b);
                        end if;
                        count := not count;
                    elsif an_g_s = '1' and vga_hborder = '1' and cvbs_vborder = '1' then
                        -- graphics mode, either green or buff (white)
                        map_palette ("00001" & css_s & "00", r, g, b);
                    else
                        r := (others => '0');
                        g := (others => '0');
                        b := (others => '0');
                    end if;
                    -- as AtomGodilVideo 52ded1f: syncs registered with the pixel
                    red    <= r;
                    green  <= g;
                    blue   <= b;
                    hsync  <= vga_hsync;
                    vsync  <= vga_vsync;
                    hblank <= not vga_hborder;
                    vblank <= not cvbs_vborder;
                end if;
            end if;  -- CVBS_NOT_VGA
        end if;  -- rising_edge(clk)
    end process PROC_OUTPUT;

    pixel_clock <= cvbs_clk_ena when CVBS_NOT_VGA else vga_clk_ena;

-- line buffer for scan doubler gives us vga monitor compatible output
    process (clk)
    begin
        if rising_edge(clk) then
            if cvbs_clk_ena = '1' then
                if (cvbs_linebuf_we_rr = '1') then
                    VRAM(conv_integer(cvbs_linebuf_addr_rr(8 downto 0))) <= pixel_char_d_o;
                end if;
            end if;
            if clk_ena = '1' then
                vga_char_d_o <= VRAM(conv_integer(vga_linebuf_addr(8 downto 0)));
            end if;
        end if;
    end process;

---- rom for char generator      
--    charrom_inst : entity work.mc6847t1_ntsc_plus_keith
--        port map(
--            CLK  => clk,
--            ADDR => char_a,
--            DATA => char_d_o
--            );

end SYN;
