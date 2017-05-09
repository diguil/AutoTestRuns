/*
 *  Test Coverage for:
 *     AutomatedTstChecker 
 *     AutomatedTstJobQueuer 
 */
@isTest(SeeAllData=true)
public with sharing class AutomatedTstTest {
    static testMethod void testDoChecker() { 
        // Make sure at least one record exists in Automated Testing Queue - recent job if found
        List<AsyncApexJob> recentJobs = [Select Id, Status from AsyncApexJob limit 1];
        String jobId = '7073C000003ugniQAA';
        if (recentJobs.size() > 0) {
            jobId = recentJobs[0].Id;    
        }
        AutomatedTestingQueue__c queuedTest = new AutomatedTestingQueue__c (Name = 'Testing Test Checker', 
                                                                            AsyncId__c = jobId );
        insert queuedTest; 
        List<AutomatedTestingQueue__c> queuedTests = [Select name, AsyncId__c, Passed__c, Failed__c, 
                                                      Test_Results__c, Notification__c  
                                                      from AutomatedTestingQueue__c ];
        Map<Id, AutomatedTestingQueue__c> queuedTestsMap = new Map<Id, AutomatedTestingQueue__c> ();
        for (AutomatedTestingQueue__c t: queuedTests) {
            queuedTestsMap.put(t.AsyncId__c, t);
        }
        // 
        AutomatedTstChecker.doExecute();
        AutomatedTstChecker.processAsyncResults();
        // build map of any queued tests - not able to insert test classes to queue as part of this test
        // so will use any already loaded - if none exist, code coverage will be impacted
        List<ApexTestQueueItem> testQItem = [SELECT ApexClass.Name, Status, ExtendedStatus, ParentJobId
                                     FROM ApexTestQueueItem Limit 20 ];
        Map<Id, List<ApexTestQueueItem>> groupedTest1ByJob = new Map<Id, List<ApexTestQueueItem>> ();
        Map<Id, List<ApexTestQueueItem>> groupedTest2ByJob = new Map<Id, List<ApexTestQueueItem>> ();
        // make sure all status values are covered
        if (testQItem.size() > 0 ){
            boolean positiveTest = true;
            if (testQItem[0].Status != 'Completed' && testQItem[0].Status != 'Failed' && testQItem[0].Status != 'Aborted') {
                positiveTest = false;
            }
            // perform test with initial value for Status
            groupedTest1ByJob = AutomatedTstChecker.groupTestsByJob(testQItem);
            AutomatedTstChecker.getCompletedAsyncJobsIds(groupedTest1ByJob);
            // do opposite test 
            if (positiveTest) {
                testQItem[0].Status = 'Running';
            } else {
                testQItem[0].Status = 'Completed';
            }
            // perform test with opposite value for Status
            groupedTest2ByJob = AutomatedTstChecker.groupTestsByJob(testQItem);
            AutomatedTstChecker.getCompletedAsyncJobsIds(groupedTest2ByJob);
        }            

        // test with a real job id if possible, otherwise use invalid id
        Set<ID> jobIds = new Set<Id> ();
        if (groupedTest1ByJob.isEmpty()) {
           jobIds.add('7073C000003k1CXQAY');
        } else {
           jobIds = groupedTest1ByJob.keySet();
        }
        AutomatedTstChecker.checkMethodStatus(jobIds);
        // test with prior testing results - these may not exist, but not able to queue/execute a test class from a test class
        List<ApexTestResult> testResults = [SELECT Outcome, MethodName, Message, StackTrace, AsyncApexJobId, ApexClass.Name,
                                                   ApexClass.Body, ApexClass.LengthWithoutComments, ApexClass.NamespacePrefix,
                                                   ApexClass.Status, ApexLogId, ApexLog.DurationMilliseconds, ApexLog.Operation,
                                                   ApexLog.Request, ApexLog.Status, ApexLog.Location, ApexLog.Application,SystemModstamp
                                            FROM ApexTestResult LIMIT 10];
        // make sure at least one failed, one passed
        if (testResults.size() > 2) {
           testResults[0].Outcome = 'Pass';
           testResults[1].Outcome = 'Fail';
        }
        String linkURl = 'testing';
        String checkHTML = AutomatedTstChecker.getTestResultHtmlEmailBody(testResults, testResults,linkURL);
        List<AutomatedTestingParameters__c> autoTestingParms = AutomatedTestingParameters__c.getall().values();
        if (autoTestingParms.size() > 0 && autoTestingParms[0].Notification_Email__c == null){
            autoTestingParms[0].Notification_Email__c = 'Test@test.com';
        } else {
            AutomatedTestingParameters__c atp = new AutomatedTestingParameters__c();
            atp.Name='TempForTest';
            atp.Notification_Email__c ='Test@test.com';
            insert atp;
        }    
        AutomatedTstChecker.checkForEmail(testResults, queuedTestsMap, queuedTests);
    }
 
    static testMethod void testDoScheduler() { 
        AutomatedTstJobQueuer.doExecute();
        AutomatedTstJobQueuer.createDailyScheduledJob('Work Day');
        AutomatedTstJobQueuer.createDailyScheduledJob('Every Day');
        List<AutomatedTestingParameters__c> autoTestingParms = AutomatedTestingParameters__c.getall().values();
        AutomatedTstJobQueuer.scheduleTestCheckerJob(autoTestingParms);
    }
}