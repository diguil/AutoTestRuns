/*   
 *  Automated Batch Test Execution
 *    1. Queues classes where name contains 'Test' into single 'Job'. 
 *    2. Adds 'Job' Id to custom object 'AutomatedTestingQueue'.
 *    3. Companion class, AutomatedTstChecker will process results. 
 *    4. Uses parameters provided via Custom Settings 'AutomatedTestNotification'
 *        - may skip test classes associated with managed packages
 *        - may resubmit self to run each calendar day or each workday at 2AM. In that case, 
 *            the companion class, AutomatedTstChecker is also scheduled and will run at 4AM.
*/
global with sharing class AutomatedTstJobQueuer implements schedulable {
   
    global void execute(SchedulableContext SC) {
        doExecute();
    }
    @future (callout=true)
    public static void doExecute(){
        // get parameters
        List<AutomatedTestingParameters__c> autoTestingParms = AutomatedTestingParameters__c.getall().values();

        enqueueUnitTests(autoTestingParms);

        // schedule test checker job              
        scheduleTestCheckerJob(autoTestingParms);
        
        // submit daily execution if required
        if (autoTestingParms.size() > 0 &&
            (autoTestingParms[0].Frequency__c == 'Work Day' || autoTestingParms[0].Frequency__c == 'Every Day')) {
             createDailyScheduledJob(autoTestingParms[0].Frequency__c);
        }
    }
    // externally enqueue 
    webservice static void enqueueUnitTests(List<AutomatedTestingParameters__c> autoTestingParms){      
        enqueueTests(autoTestingParms);
    } 
    /*
     *  enqueue specified test classes  
     */
    public static void enqueueTests(List<AutomatedTestingParameters__c> autoTestingParms) {
       // build query string
       string nameSearch = '%Test%';
       string testQuery = 'Select Id, Name from ApexClass where Name like :nameSearch';
       if (autoTestingParms.size() == 0 || 
          (autoTestingParms.size() > 0 && 
           (!autoTestingParms[0].Include_Installed_Package_Tests__c ||
             autoTestingParms[0].Include_Installed_Package_Tests__c == null))) {
             testQuery += ' AND NamespacePrefix = \'\'';
       }
       
       ApexClass[] testClasses = Database.query(testQuery);
       system.debug('&&&& testClasses:'+testClasses.size());
       // set # of test classes found             
       Integer testClassCnt = testClasses != null ? testClasses.size() : 0;
       if (testClassCnt > 0) {
          // Insertion of the ApexTestQueueItem causes the unit tests to be executed. Since they're asynchronous, 
          // the apex async job id needs to be stored somewhere so test results can be obtained
          ApexTestQueueItem[] queueItems = new List<ApexTestQueueItem>();
          for (ApexClass testClass : testClasses) {
              queueItems.add(new ApexTestQueueItem(ApexClassId=testClass.Id));
          }
           try {
            insert queueItems;
           } catch (System.DmlException e) {
                system.debug('#### error:'+e);
           
           }
          // Get the job ID from the first queue item as all share the same parent 
          List<ApexTestQueueItem> item = [SELECT ParentJobId FROM ApexTestQueueItem WHERE Id=:queueItems[0].Id LIMIT 1];
          // store this job id 
          if (item.size() > 0) {
            AutomatedTestingQueue__c atq = new AutomatedTestingQueue__c(AsyncId__c = item[0].parentjobid);
            insert atq; 
          }
       }
    }
    /*
     * schedules run of job queuer based on parameter value
     */     
    public static void createDailyScheduledJob(String frequency){
        try {
            if (frequency == 'Work Day') {
                string dailyAt2AM = '0 0 2 ? * MON-FRI';  
                AutomatedTstJobQueuer atj = new AutomatedTstJobQueuer();  
                system.schedule('Automated Work Day Test Queuer',dailyAt2AM,atj);
            } else {
                string dailyAt2AM = '0 0 2 ? * *';  
                AutomatedTstJobQueuer atj = new AutomatedTstJobQueuer();  
                system.schedule('Automated Daily Test Queuer',dailyAt2AM,atj);
            }
        } catch(exception e) {
            if (!e.getMessage().contains('already scheduled')) {
                system.debug('#### Scheduler Failed for Automated Job Queuer.');
            }  
        }
    }
    /*
     * schedules run of test checker in x hours      
    */     
    public static void scheduleTestCheckerJob(List<AutomatedTestingParameters__c> autoTestingParms){
        
        Integer waitTime = 3;
        if (autoTestingParms.size() > 0 && 
            autoTestingParms[0].Wait_Time_for_Checker__c != null) {
             waitTime = autoTestingParms[0].Wait_Time_for_Checker__c.intValue();
        }
        
        String hour = String.valueOf(Datetime.now().hour() + waitTime);
        String min = String.valueOf(Datetime.now().minute());
        String ss = String.valueOf(Datetime.now().second()); 
        
        String nextFireTime = ss + ' ' + min + ' ' + hour + ' * * ?';

        try {
                AutomatedTstChecker atc = new AutomatedTstChecker();  
                system.schedule('Automated Test Check',nextFireTime,atc);
        } catch(exception e) {
            if (!e.getMessage().contains('already scheduled')) {
                system.debug('#### Scheduler Failed for Automated Test Checker.');
            }  
        }
    }
}