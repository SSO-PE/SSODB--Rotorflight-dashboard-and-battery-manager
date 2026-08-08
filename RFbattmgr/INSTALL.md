This is a Battery manager / dashboard for EdgeTX to be used with Rotorflight telemetry.



## == PREREQUISITES ==



\* \*\*Radio OS:\*\* EdgeTX v2.8 or newer with Touchscreen support (480x320 resolution - no other resolution has been tested, e.g., RadioMaster TX15).

\* \*\*Flight Controller:\*\* Rotorflight 2.0+ with active telemetry enabled (CRSF/ELRS or S.Port).

\* \*\*RFTOOLS lua needs to be installed and active on another screen of EdgeTX -- The model name is taken from this lua-script.



## == FEATURES ==

This widget has 3 screens:

\- Flight information screen (main screen)

&#x09;- Timer

&#x09;- Battery name (press to enter the battery select screen)

&#x09;- Battery bar

&#x09;- Headspeed / Throttle mode (on - idle - off)

&#x09;- Bank

&#x09;- Armed / disarmed

&#x09;- Telemetry

\- Battery select screen

&#x09;- Pops up when connecting model

&#x09;- A Battery can be assigned to multiple models.

&#x09;- Rotorflight Integration: Each battery is assigned a model-specific profile number (1–6) that corresponds directly to Rotorflight's battery profiles.

&#x09;  Upon selection, this index is scaled to -1024 / +1024. This scaled value is written to an EdgeTX Global Variable (GV), which can be used in inputs or mixes, allowing Rotorflight to automatically sync and load the matching battery profile.

\- Battery edit screen

&#x09;- Allows creating, editing, deleting batteries

&#x09;- Input battery name

&#x09;- Input battery capacity (not used for calculations)

&#x09;- Input battery

&#x09;- Allows assigning batteries to models

&#x09;- For a new battery, the widget automatically assigns a model specific profile number so no duplicates are possible.

\- Post-flight screen

&#x09;- Pops up when disconnecting model

&#x09;- Gives summary of most important telemetry values

&#x09;	- Flight Time

&#x09;	- Max ESC temperature

&#x09;	- Max ESC current

&#x09;	- Min cell voltage, etc

&#x09;- Closes automatically after 5 minutes

&#x09;- Closes automatically when a model is connected



The widget uses a .bmp background for the flight screen. This avoids drawing multiple rectangles over top of the background.



Includes: 

\- Flight counter per battery 



&#x09;



## == INSTALLATION \& SETUP==

To install the widget, simply copy the files in repository and paste them in the WIDGETS folder of the transmitter.

The widget needs to be set up in multiple steps:



### **STEP 1 (Optional): Edit the batteries.lua file located in WIDGETS/RFbattmgr**

**For initial setup it is recommended to manually edit the batteries.lua**:

If you don't know what you're doing, stick to the setup in touch-ui.

For every battery: adjust the settings below and copy paste in the batteries.lua

&#x20; {

&#x20;   name = "battery name",

&#x20;   cap = capacity,

&#x20;   flights = #,

&#x20;   models = {

&#x20;     \["model 1"] = 1,

&#x20;     \["model 2"] = 2

&#x20;   }

&#x20; },



##### EXPLANATION:

&#x20; {

&#x20;   name = "battery name", 	//Display name shown on the touch UI (max \~18 characters recommended).

&#x20;   cap = capacity, 		// Battery nominal capacity in mAh (e.g., 2200, 5000).

&#x20;   flights = #, 		//Accumulated flight count for this pack. Automatically increments upon land/disconnect.

&#x20;   models = {

&#x20;     \["model 1"] = 1, 		//The first model name assigned to this battery, in order for the filtering to work correctly, this name needs to be the same as the one entered in Rotorflight. -- This will be battery 1 in Rotorflight for model 1

&#x20;     \["model 2"] = 3		//The second model name assigned to this battery -- This will be the battery 3 in Rotorflight for model 2

&#x20;   }

&#x20; },





***IMPORTANT: Make sure that within the model, no batteries share the same battery number***





##### EXAMPLE:

return {

&#x20; {

&#x20;   name = "GensAce 6S 1800mAh #1",

&#x20;   cap = 1800,

&#x20;   flights = 12,

&#x20;   models = {

&#x20;     \["RAW 420"] = 1,

&#x20;     \["SAB Goblin 380"] = 2

&#x20;   }

&#x20; },

&#x20; {

&#x20;   name = "OptiPower 6S 5000mAh",

&#x20;   cap = 5000,

&#x20;   flights = 5,

&#x20;   models = {

&#x20;     \["Kraken 580"] = 1

&#x20;   }

&#x20; },

&#x20; {

&#x20;   name = "Field Utility 3S 2200",

&#x20;   cap = 2200,

&#x20;   flights = 0,

&#x20;   models = {} -- Global battery (visible on all models)

&#x20; }

}



### **STEP 2: INSTALL WIDGET**

Copy the entire RFbattmgr folder and paste the folder in the WIDGETS folder of your EdgeTX radio





### **STEP 3: CONFIGURE WIDGET**

\- Make sure all Telemetry sensors are already discovered in EdgeTx

\- Add the widget to a screen using the Full screen lay outoption

\-  Adjust the widget settings:
Telemetry data:

&#x09;- Rem%: insert RotorFlight telemetry sensor Bat%

&#x09;- Capa: insert RotorFlight telemetry sensor for used battery capacity (Capa)

&#x09;- VOLT: insert RotorFlight telemetry sensor for battery voltage (Vbat)

&#x09;- Cell: insert RotorFlight telemetry sensor for average cell voltage (Vcel)

&#x09;- Curr: insert Rotorflight telemetry sensor for ESC current (Iesc)

&#x09;- EscT: insert Rotorflight telemetry sensor for ESC temperature (Tesc)

&#x09;- RQly: insert telemetry sensor for link quality (RQly)

&#x09;- RpmSrc: insert Rotorflight headspeed telemetry sensor for headspeed (Hspd)

&#x09;- Bec: insert Rotorfllight telemetry sensor for BEC voltage (Vbec)
The following setttings are tracked sensors by EdgeTX:

&#x09;- MinCell: insert telemetry sensor for minimum average cell voltage (Vcel-)

&#x09;- MaxCurr: insert telemetry sensor for maximum ESC current (Iesc+)

&#x09;- MaxESCT: insert telemetry sensor for maximum ESC temperature (Tesc+)

&#x09;- MinRQly: insert telemetry sensor for minimum link quality (RQly-)

Other settings:

&#x09;- TxtCol: changes the color of the text
- GV\_Select: Choose a free global variable - used for storing the selected battery

\- TimerSrc: 1= Timer 1 in EdgeTx

\- ModeSrc: Input the source for Throttle (On / Idle / Off)

\- BankSrc: Input the source for bank (profile) switching

\- Bank 1\_2: As BankSrc changes this sets the point at which bank 1 switches to Bank 2 (default: -500)

\- Bank 2\_3: this sets the point at which bank 2 switches to Bank 3 (default: 250)



### 

### **STEP 3: SETUP THE BATTERY SELECT CHANNEL:**

To transmit the selected Global Variable to Rotorflight:



EdgeTX Mixer: Go to the MIXES page in EdgeTX and create a new mix on an unused channel (e.g., CH8):

Source: Select the same GV configured in Step 2 (e.g., GV1).

Weight: 100%



### **STEP 4: SETUP BATTERIES (if not done through STEP 1)**



\- Acces Edit screen:
	1. From the flight screen, tap the Battery name to enter the Battery Select screen

&#x09;2. In the Battery Select screen, tap the Edit button

\- Create new Battery:

&#x09;1. Click Add on the bottom left of the screen

&#x09;2. On the right side tap Edit Name and enter the name of your battery. Click Done to return to the edit screen

&#x09;3. Tap Edit capacity and enter the capacity of your battery. Click Done to return to the edit screen

&#x09;4. (Optional) Tap Edit Flights: enter the number of flights the battery has already done

\- Assign models to battery:

&#x09;1. Tap the models button

&#x09;2. Click the "+ Add Model" button

&#x09;3. Enter the model name, making sure it matches with the Rotorflight model name. Click Done to return to the models screen

&#x09;4. The widget will auto assign a number to the battery. This correlates to the battery number in Rotorflight. 
	   To change this number tap the number and select which number needs to be used.

&#x09;5. Add a second model if batteries are shared between models

&#x09;6. Click Close

\- Tap the Save button to save these changes. Tapping the back button without saving will undo all changes made in this screen.



### **STEP 5: CONFIGURATION OF BATTERIES IN ROTORFLIGHT**

This widget uses raw telemetry values and avoids doing calculations that are already done by EdgeTX or RotorFlight.

Setup the batteries in RotorFlight according to the RotorFlight documentation. Make sure to input the correct battery capacity

Note: the original intention of the widget was to insert 80% of the total battery capacity in RotorFlight - Rem% = 0 when actually 20% remains.

In other words: it's advised to use the USABLE capacity in the battery settings of RotorFlight.









&#x09;

