#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"
#include "hardware/gpio.h"
#include "hardware/adc.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"

// To compile, mkdir build; cd build;
// export PICO_SDK_PATH=/home/dbannon/Pico2/SDK   // that being where SDK lives, contains dir like pico-examples and external.
// cmake -DPICO_BOARD=pico_w ..  // don't miss the '..' !
// make    // slow !

//  To read the attached debug pico, "tio /dev/ttyACM0", ctrl-T to get menu, ctrl-t, q to quit.
//  Make sure you are in the dialout group to use serial port (ie USB).
//  Because of setting setting in CMakeList.txt we don't need to use the debug probe.
//  else Plug in the debug pico to see debug info. 

char SSID[] = "iiNetB50DEB";
char PASS[] = "--PASSWORD--";
char TARGET_IP[] = "192.168.1.XXX";    // the real logger Pi

char MsgBuff[255];                  // where we put the message to send

#define BUF_SIZE 2048
#define PORT 4100
#define TEST_ITERATIONS 10
#define POLL_TIME_S 5
#define DUMP_BYTES(A,B)

// ------------ D E F I N E S   and   T Y P E S   for   H O T W A T E R -------- 

enum TPumpState {psOff, psCollectHot, psCollectFreeze};

  //#define  BAUD_RATE 115200;
  // ADC_REF_VOLT=2490;      // milliVolts
  // ADC_REF_VOLT=3300;   // milliVolts
#define  PumpOnDelta       3.0     // Collector has to be this much hotter than tank to turn pump on
#define  PumpOffDelta      2.0     // Collector has to be this much hotter than tank for Pump to remain on
#define  MaxTankTemp       90.0    // Don't send any more hot water to tank !
#define  AntiFreezeTrigger 3.0     // Colder than this, we must pump some warm water up
#define  AntiFreezeRelease 4.0     // Warmer than this, we can stop pumping
#define  PumpPort          19      // TPicoPin.GP19        // GP19 conflicts with SPI-0 and I2C-1  (and UART 0 ??)
#define  PtSelectPort      22      // TPicoPin.GP22    // GP22 conflicts with SPI-0 and I2C-1  (and UART 1 ??)
#define  CntsPerReading    10      // We take multiple ADC readings

// --------- Board Sensitive --------
#define ADC0 0                     // GP26    When speaking to ADC functions, we must 
#define ADC1 1                     // GP27    use the 0..3 syntax, but when using the
#define ADC2 2                     // GP28    gpio unit (ie doing init) quote it GP number.

  bool AntiFreezeOn = false;
  enum TPumpState PumpState = psOff;
  int TCP_Count = 0;                     // Only sent a TCP report when this reaches X    
  
  
// -------------------------   T C P   C O D E ---------------------------------

  
typedef struct TCP_CLIENT_T_ {
    struct tcp_pcb *tcp_pcb;
    ip_addr_t remote_addr;
    uint8_t buffer[BUF_SIZE];
    int buffer_len;
    int sent_len;
    bool complete;
    int run_count;
    bool connected;
} TCP_CLIENT_T;

static err_t tcp_client_close(void *arg) {
    TCP_CLIENT_T *state = (TCP_CLIENT_T*)arg;
    err_t err = ERR_OK;
    if (state->tcp_pcb != NULL) {
        tcp_arg(state->tcp_pcb, NULL);
        tcp_poll(state->tcp_pcb, NULL, 0);
        tcp_sent(state->tcp_pcb, NULL);
        tcp_recv(state->tcp_pcb, NULL);
        tcp_err(state->tcp_pcb, NULL);
        err = tcp_close(state->tcp_pcb);
        if (err != ERR_OK) {
            printf("close failed %d, calling abort\n", err);
            tcp_abort(state->tcp_pcb);
            err = ERR_ABRT;
        }
        state->tcp_pcb = NULL;
    }
    return err;
}

// Called with results of operation
static err_t tcp_result(void *arg, int status) {
    TCP_CLIENT_T *state = (TCP_CLIENT_T*)arg;
    if (status == 0) {
        printf("tcp send success\n");
    } else {
        printf("tcp send failed %d\n", status);
    }
    state->complete = true;
    return tcp_client_close(arg);
}

static err_t tcp_client_sent(void *arg, struct tcp_pcb *tpcb, u16_t len) {
    TCP_CLIENT_T *state = (TCP_CLIENT_T*)arg;
    //printf("tcp_client_sent %u\n", len);
    state->sent_len += len;
    if (state->sent_len >= BUF_SIZE) {
        state->run_count++;
        if (state->run_count >= TEST_ITERATIONS) {
            tcp_result(arg, 0);
            return ERR_OK;
        }
        // We should receive a new buffer from the server
        state->buffer_len = 0;
        state->sent_len = 0;
        printf("Waiting for buffer from server\n");
    }
    // Ugly hack. Don't want to wait for client to time out but calling tcp_result
    // immedietly after _sent is called crashes us here if server is bounced.
    // 100mS seems enough and is not a problem for timing.  
    busy_wait_ms(100);
    tcp_result(arg, ERR_OK);            // kill off connection after one send.
    // return ERR_OK;
}

static err_t tcp_client_connected(void *arg, struct tcp_pcb *tpcb, err_t err) {
    TCP_CLIENT_T *state = (TCP_CLIENT_T*)arg;
    if (err != ERR_OK) {
        printf("connect failed %d\n", err);
        return tcp_result(arg, err);
    }
    state->connected = true;      
    tcp_write(state->tcp_pcb, MsgBuff, strlen(MsgBuff), 0);

    err = tcp_output(state->tcp_pcb);                  // drb    
//    printf("Connected has written.\n");
    return ERR_OK;  
}
    // Poll seems to get called when client is sick of waiting, a few seconds ??
static err_t tcp_client_poll(void *arg, struct tcp_pcb *tpcb) {
    printf("tcp_client_poll\n");
    return tcp_result(arg, -1); // no response is an error?  -1, indicating an error
}

static void tcp_client_err(void *arg, err_t err) {
    if (err != ERR_ABRT) {
        printf("tcp_client_err %d\n", err);
        tcp_result(arg, err);
    }
}

err_t tcp_client_recv(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err) {
    TCP_CLIENT_T *state = (TCP_CLIENT_T*)arg;
    printf("tcp received\n");
    if (!p) {
        return tcp_result(arg, -1);
    }
    // this method is callback from lwIP, so cyw43_arch_lwip_begin is not required, however you
    // can use this method to cause an assertion in debug mode, if this method is called when
    // cyw43_arch_lwip_begin IS needed
    cyw43_arch_lwip_check();
    if (p->tot_len > 0) {
        printf("recv %d err %d\n", p->tot_len, err);
        for (struct pbuf *q = p; q != NULL; q = q->next) {
            DUMP_BYTES(q->payload, q->len);
        }
        // Receive the buffer
        const uint16_t buffer_left = BUF_SIZE - state->buffer_len;
        state->buffer_len += pbuf_copy_partial(p, state->buffer + state->buffer_len,
                                               p->tot_len > buffer_left ? buffer_left : p->tot_len, 0);
        tcp_recved(tpcb, p->tot_len);
    }
    pbuf_free(p);

    // If we have received the whole buffer, send it back to the server
    if (state->buffer_len == BUF_SIZE) {
        printf("Writing %d bytes to server\n", state->buffer_len);
        err_t err = tcp_write(tpcb, state->buffer, state->buffer_len, TCP_WRITE_FLAG_COPY);
        if (err != ERR_OK) {
            printf("Failed to write data %d\n", err);
            return tcp_result(arg, -1);
        }
    }
    return ERR_OK;
}

static bool tcp_client_open(void *arg) {
    TCP_CLIENT_T *state = (TCP_CLIENT_T*)arg;
    //printf("Connecting to %s port %u\n", ip4addr_ntoa(&state->remote_addr), PORT);
    // https://lwip.nongnu.org/2_1_x/group__tcp__raw.html
    state->tcp_pcb = tcp_new_ip_type(IP_GET_TYPE(&state->remote_addr));
    if (!state->tcp_pcb) {
        printf("failed to create pcb\n");
        return false;
    }

    tcp_arg(state->tcp_pcb, state);
    tcp_poll(state->tcp_pcb, tcp_client_poll, POLL_TIME_S * 2);
    tcp_sent(state->tcp_pcb, tcp_client_sent);
    tcp_recv(state->tcp_pcb, tcp_client_recv);
    tcp_err(state->tcp_pcb, tcp_client_err);

    state->buffer_len = 0;

    // cyw43_arch_lwip_begin/end should be used around calls into lwIP to ensure correct locking.
    // You can omit them if you are in a callback from lwIP. Note that when using pico_cyw_arch_poll
    // these calls are a no-op and can be omitted, but it is a good practice to use them in
    // case you switch the cyw43_arch type later.
    cyw43_arch_lwip_begin();
    err_t err = tcp_connect(state->tcp_pcb, &state->remote_addr, PORT, tcp_client_connected);
    // ToDo : check that error state.    
//    tcp_write(state->tcp_pcb, "hello everyone", 14, 0);       // DRB
//    err_t err = tcp_output(state->tcp_pcb);                   // drb
    
    cyw43_arch_lwip_end();

    return err == ERR_OK;
}

// Perform initialisation
static TCP_CLIENT_T* tcp_client_init(void) {
    TCP_CLIENT_T *state = calloc(1, sizeof(TCP_CLIENT_T));
    if (!state) {
        printf("failed to allocate state\n");
        return NULL;
    }
    ip4addr_aton(TARGET_IP, &state->remote_addr);
    return state;
}

void run_tcp_client() {
    TCP_CLIENT_T *state = tcp_client_init();
    if (!state) {
        return;
    }
    if (!tcp_client_open(state)) {
        tcp_result(state, -1);
        return;
    }
    while(!state->complete) {
        /* We are NOT in POLL mode. I have removed the (small) POLL block. */
        sleep_ms(1000);
    }
    free(state);
}

// ------------------------- H O T   W A T E R   C O N T R O L -----------------

// Returns indicated Temp corrected for zero offset
float GetExternalTemperature(int8_t SelectADC) {
    float Cnt = 0.0;
    gpio_put(PtSelectPort, (SelectADC==ADC1));   // high switches constant current to collector Pt
    adc_select_input(SelectADC);                 // select the ADC port to use
    busy_wait_us_32(100);                        // Settle ....
    int i;
    for (i = 1; i <= CntsPerReading; i++) {      
#ifdef TESTMODE                                     // 2277 counts 100C, 1644 0C, 1963 50C
        if (SelectADC==ADC1) Cnt = Cnt + 1644.0;    // Collector 
        else Cnt = Cnt + 1963;                      // Tank
#else
        Cnt = Cnt + (float)adc_read();
#endif
    }
#ifndef TESTMODE
    adc_select_input(ADC2);                     // Input ADC2 is tied to gnd, account for any offset
    for (i = 0; i < CntsPerReading; i++) {
        Cnt = Cnt - (float)adc_read();
    } 
#endif
    // return ((Cnt * 158) / 10) - 259740;      // thats milli degrees   ADJUST THIS !!!!
    return (((Cnt * 15.8)  - 259740)/1000.0);   // really, really, check this !!!!
}


void Report(float Collect, float Tank) {
    char PumpSt[] = "CollectFreeze";
    
    switch (PumpState) {
        case psOff :
            printf("Pump is OFF, Collector %.2f and Tank %.2f, Count=%d\n", Collect, Tank, TCP_Count);
            sprintf(PumpSt, "%s", "OFF");
            break;
        case psCollectHot :
            printf("Pump is ON (hot), Collector %.2f and Tank %.2f, Count=%d\n", Collect, Tank, TCP_Count);
            sprintf(PumpSt, "%s", "COLLECTHOT");
            break;
        case psCollectFreeze :
            printf("Pump is ON (freeze), Collector %.2f and Tank %.2f, Count=%d\n", Collect, Tank, TCP_Count);
            break;
        default:
            printf("Pump is OFF but why are we here ?  Collector %f and Tank %f, Count=%d\n", Collect, Tank, TCP_Count);
            break;
    }
    //printf("Report : count is %d\n", TCP_Count);
    if (TCP_Count > 60) {
        sprintf(MsgBuff, "%d,%d,%s", (int)(Collect*1000.0), (int)(Tank*1000.0), PumpSt);
        // Pass an int, being milli degrees C, to be consistent with how capture works.
        // Note assuming ints on the Pico are greater than 16bit !
        run_tcp_client();
        TCP_Count = 0;
    } else TCP_Count++;
}    

                // Called repeatedly until power off.
void ControlLoop() {
    //float CollectorTemp = GetExternalTemperature(1, true);
    //float TankTemp = GetExternalTemperature(0, false);
    float CollectorTemp = GetExternalTemperature(ADC1);
    float TankTemp = GetExternalTemperature(ADC0);
    switch (PumpState) {
        case psOff :                // if its OFF, we might turn it on
            if (CollectorTemp < AntiFreezeTrigger) 
                PumpState = psCollectFreeze;
            else if ((CollectorTemp > (TankTemp + PumpOnDelta)) 
                && (TankTemp < MaxTankTemp)) 
                    PumpState = psCollectHot;
            break;
        case (psCollectHot) :       // Already collecting, so we may turn it off.
            if (CollectorTemp < (TankTemp + PumpOffDelta)) 
                PumpState = psOff;
            break;
        case (psCollectFreeze) :    // pumping 'cos of freeze ? We may turn it off.
            if (CollectorTemp > AntiFreezeRelease)
                PumpState = psOff;
            break;
        default :                   // not possible ?  Anyway, we'll set it off.
            PumpState = psOff;
    }                               // end of switch statement.
    if ((PumpState == psCollectHot) || (PumpState == psCollectFreeze))
        gpio_put(PumpPort, true);                                // Make it so.
    else gpio_put(PumpPort, false);
    sleep_ms(500); 
    Report(CollectorTemp, TankTemp);
    // sleep_ms(250);
}


// ------------------------- M A I N   F U N C T I O N -------------------------
int main() {
    stdio_init_all();
    gpio_init(PumpPort);
    gpio_set_dir(PumpPort, true);      // Apparently out is true ??
    gpio_init(PtSelectPort);
    gpio_set_dir(PtSelectPort, true);
    adc_init();
    // Make sure GPIO is high-impedance, no pullups etc
    adc_gpio_init(26);        // Thats GP26, ADC0, the Tank Temp
    adc_gpio_init(27);        // And thats GP27, ADC1, the Collector on the roof.
    adc_gpio_init(28);        // Thats GP28, ADC2, our offset input, tied to gnd
    printf("Ctrl setup, now look for network\n");
    sleep_ms(2000);             // A little wait for tio to catch up    
    if (cyw43_arch_init()) {
        printf("failed to initialise\n");
        return 1;
    }
    cyw43_arch_enable_sta_mode();
    
    printf("Connecting to %s on port %d\n", TARGET_IP, PORT);
    
    printf("Connecting to WiFi...\n");
    if (cyw43_arch_wifi_connect_timeout_ms(SSID, PASS, CYW43_AUTH_WPA2_AES_PSK, 30000)) {
        printf("failed to connect to WiFi.\n");
        return 1;
    } else {
        printf("Connected to WiFi.\n");
    }
    while (true) {
        ControlLoop();     
    }    
    // We never get to here. Is that a bad thing ?    
    cyw43_arch_deinit();
    puts("My work here is done.");
    return 0;
}

/* Main calls run_tcp_client_test();
    run_tcp_client_test() calls -
        tcp_client_init();
            creates and populates the state structure
        tcp_client_open(state)
            further populates state with a pcb
            assigns poll, sent, receive and error function. (poll has a time seetting ??)
            lwip_begin();
                connect
                ? write
                ? output
            lwip_end();    
        ... and then starts a loop.
*/        
     
