/* Class scheduled via Salesforce 'Schedule Apex' to run weekly/monthly.  
 * Can also be flagged via Custom Settings 'AutomatedTestingParameters' to run each week day or calendar day at 4AM after
 * its companion class, AutomatedTstJobQueuer, which is scheduled to run at 2AM.
*/
global class AutomatedTstChecker implements Schedulable {
    global void execute(SchedulableContext SC) {
        doExecute();
    }
    @future (callout=true)
    public static void doExecute(){
        processAsyncResults();
    }

    
    public static void processAsyncResults(){
		// get test jobs
        List<AutomatedTestingQueue__c> queuedTests = [select id, name, AsyncId__c, Passed__c, Failed__c, 
                                                      Test_Results__c, Notification__c  
                                                      from AutomatedTestingQueue__c 
                                                      where Notification__c = null  limit 5];
        
        if (queuedTests != null && queuedTests.size() > 0){
			// get all the job ids, map job data
            Set<Id> AsyncIds = new Set<Id>();
        	map<Id,AutomatedTestingQueue__c> testJobsMap = new map<Id,AutomatedTestingQueue__c>();
            for (AutomatedTestingQueue__c queuedJob : queuedTests){
                 AsyncIds.add(queuedJob.AsyncId__c);
                 testJobsMap.put(queuedJob.AsyncId__c, queuedJob);
            }

            // build map of job id to queued tests           
            List<ApexTestQueueItem> queuedItems = checkClassStatus(AsyncIds);
            map<Id, List<ApexTestQueueItem>> groupedTestsByJob = groupTestsByJob(queuedItems);

            // get ids for all jobs that completed            
            Set<Id> completedAsyncIds = getCompletedAsyncJobsIds(groupedTestsByJob);

            if (completedAsyncIds != null && completedAsyncIds.size() > 0){
				// get results of tests            
                List<ApexTestResult> testResults = checkMethodStatus(completedAsyncIds);
                Map<Id, List<ApexTestResult>> groupedTestResultsByJob = new Map<Id, List<ApexTestResult>>();
                for (ApexTestResult testResult : testResults){
                    if (groupedTestResultsByJob.containsKey(testResult.AsyncApexJobId)){
                        List<ApexTestResult> groupedTestsResults = groupedTestResultsByJob.get(testResult.AsyncApexJobId);
                        groupedTestsResults.add(testResult);
                    }
                    else{
                        List<ApexTestResult> groupedTestsResults = new List<ApexTestResult>();
                        groupedTestsResults.add(testResult);
                        groupedTestResultsByJob.put(testResult.AsyncApexJobId, groupedTestsResults );
                    }
                }
				// check if email of results should be sent
                list<AutomatedTestingQueue__c> updatedJobs = new list<AutomatedTestingQueue__c> ();
                for (List<ApexTestResult> jobTestResults : groupedTestResultsByJob.values()){
                    checkForEmail(jobTestResults, testJobsMap, updatedJobs );
                }
				// update jobs data
                if (updatedJobs.size() > 0) {
                	update updatedJobs;
                }
            }
        }
		// cleanup for jobs completed successfully more than x days ago 
		// - specified via custom setting AutomatedTestingParameters
        List<AutomatedTestingParameters__c> autoTestingParm = AutomatedTestingParameters__c.getall().values();
        Integer keepDays = -30;
        if (autoTestingParm.size() > 0 &&
            autoTestingParm[0].History_Days__c != null) {
            keepDays = -1 * autoTestingParm[0].History_Days__c.intValue();
        }
        Date xDaysAgo = system.Today().addDays(keepDays);
        List<AutomatedTestingQueue__c> queuedTestsToDelete = new List<AutomatedTestingQueue__c>([Select Id from AutomatedTestingQueue__c
         																 where LastModifiedDate < :xDaysAgo]); 
        if (queuedTestsToDelete.size() > 0){
             delete queuedTestsToDelete;
        }
    }
	/*
	 *   build map of job id to tests
	*/    
    public static Map<Id, List<ApexTestQueueItem>> groupTestsByJob(List<ApexTestQueueItem> apexTests){
    	Map <Id,List<ApexTestQueueItem>> groupedTestsByJob = new Map <Id,List<ApexTestQueueItem>> (); 
        for (ApexTestQueueItem atqi : apexTests){
            if (groupedTestsByJob.containsKey(atqi.ParentJobId) == true){
                List<ApexTestQueueItem> groupedTests = groupedTestsByJob.get(atqi.ParentJobId);
                groupedTests.add(atqi);
            } else{
                List<ApexTestQueueItem> groupedTests = new List<ApexTestQueueItem>();
                groupedTests.add(atqi);
             	groupedTestsByJob.put(atqi.ParentJobId, groupedTests);
            }
        }
        return groupedTestsByJob;
    }
	/*  
	 * for each job id will check to see if included test classes have completed successfully
	*/    
    public static Set<Id> getCompletedAsyncJobsIds(Map<Id, List<ApexTestQueueItem>> groupedTestsByJob){
        Set<Id> completedAsyncJobIds = new Set<Id>();


        // for each queued item (test class) in the job, check to see if it completed successfully
        for (List<ApexTestQueueItem> jobTests : groupedTestsByJob.values()){
            if (jobTests == null || jobTests.size() == 0){
                continue;
            }
            Boolean allCompleted = true;
            for (ApexTestQueueItem queuedTest : jobTests){
                if (queuedTest.Status != 'Completed' && queuedTest.Status != 'Failed' && queuedTest.Status != 'Aborted'){
                    allCompleted = false;
                    break;
                }
            }
			// add the successful job to the set            
            if (allCompleted == true){
                completedAsyncJobIds.add(jobTests[0].ParentJobId);
            }
        }
        return completedAsyncJobIds;
    }
	/* 
	 * sends email if any tests failed and email address provided via Custom Setting
	 * updates job record in custom table  
	 */
    public static void checkForEmail(List<ApexTestResult> jobTestResults, map<Id,AutomatedTestingQueue__c> testJobsMap, List<AutomatedTestingQueue__c> updatedJobs){
        List<ApexTestResult> successTests = new List<ApexTestResult>();
        List<ApexTestResult> failedTests = new List<ApexTestResult>();
		// check each test for pass/fail   & determine time that last test completed
        datetime lastTestCompleted;
        for (ApexTestResult jobTestResult : jobTestResults){
            if (jobTestResult.Outcome == 'Pass'){
                successTests.add(jobTestResult);
            } else {
                failedTests.add(jobTestResult);
            }
            if (lastTestCompleted == null || jobTestResult.SystemModstamp > lastTestCompleted) {
                lastTestCompleted = jobTestResult.SystemModstamp;
            }
        }
        // populate job record
        if (testJobsMap.get(jobTestResults[0].AsyncApexJobId) != null ) {
             testJobsMap.get(jobTestResults[0].AsyncApexJobId).Passed__c = successTests.size();
             testJobsMap.get(jobTestResults[0].AsyncApexJobId).Failed__c = failedTests.size();
             testJobsMap.get(jobTestResults[0].AsyncApexJobId).Last_Test_Completed__c = lastTestCompleted;
        }
        // get email address(es) for test results notification
        Map<String, AutomatedTestingParameters__c> autoTestingParm = AutomatedTestingParameters__c.getall();
        List <String> toAddresses = new List<String>();
        for (AutomatedTestingParameters__c p: autoTestingParm.values()) {
        	if (p.Notification_Email__c != null) {
                toAddresses.add(p.Notification_Email__c);
            }
        }
		// format results if any tests failed         
		if (failedTests.size() > 0 && testJobsMap.get(jobTestResults[0].AsyncApexJobId) != null) {
        	string linkToResults = URL.getSalesforceBaseUrl().toExternalForm() + '/' + testJobsMap.get(jobTestResults[0].AsyncApexJobId).Id;

            testJobsMap.get(jobTestResults[0].AsyncApexJobId).Test_Results__c = getTestResultHtmlEmailBody(failedTests, successTests, linkToResults);
        }
		// only send email if a test method failed and a notification email address exists
		if (failedTests.size() > 0  && toAddresses.size() > 0) {
            try {
             	Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setToAddresses(toAddresses);
                mail.setBccSender(false);
             	mail.setSenderDisplayName('Salesforce Automated Unit Tests');
                Organization thisOrg = [select Id, Name, InstanceName, IsSandbox, OrganizationType from Organization
                                            where Id =: UserInfo.getOrganizationId() limit 1];
                string subject = 'Salesforce ';
                if (thisOrg.isSandbox) {
                    subject += 'Sandbox Instance '+thisOrg.InstanceName + ' Automated Test Job';
                } else {
                    subject += 'Production Org '+thisOrg.Name + ' Automated Test Job' ;
                }
                if (testJobsMap.get(jobTestResults[0].AsyncApexJobId) != null) {
                    mail.setSubject(subject + ': ' + jobTestResults[0].AsyncApexJobId + ' - Completed with Errors');
             		mail.setHtmlBody(testJobsMap.get(jobTestResults[0].AsyncApexJobId).Test_Results__c);
                } else {
                    mail.setSubject(' - Completed with Errors');
             		mail.setPlainTextBody('Missing Job ID');
                }
             	// reserve email capacity for the current Apex transaction to ensure daily limits are not exceeded
                Messaging.reserveSingleEmailCapacity(2);
             	Messaging.sendEmail(new Messaging.SingleEmailMessage[] {mail});
                if (testJobsMap.get(jobTestResults[0].AsyncApexJobId) != null) {
             		testJobsMap.get(jobTestResults[0].AsyncApexJobId).Notification__c = 'Email';
                    testJobsMap.get(jobTestResults[0].AsyncApexJobId).Email_Sent__c = true;
                }
            } catch(exception e) {
                // handle error if sandbox/organization is not permitted to send email
                if (e.getMessage().contains('not permitted to send email')) {
                	if (testJobsMap.get(jobTestResults[0].AsyncApexJobId) != null) {
             			testJobsMap.get(jobTestResults[0].AsyncApexJobId).Notification__c = 'Email Not Allowed';
                	}
                } else {
                    system.debug('&&&& Job has failed. Issue encountered when sending email.');
                    system.assertEquals(1,0,'Failed. Issue encountered when sending email');
                }
            }
          } else {
                if (testJobsMap.get(jobTestResults[0].AsyncApexJobId) != null) {
             		testJobsMap.get(jobTestResults[0].AsyncApexJobId).Notification__c = 'No Email Needed';
                }
		}
        if (testJobsMap.get(jobTestResults[0].AsyncApexJobId) != null) {
	        updatedJobs.add(testJobsMap.get(jobTestResults[0].AsyncApexJobId));
        }
    }

    /*
     *  format test results 
     */
    public static String getTestResultHtmlEmailBody(List<ApexTestResult> failedTests, List<ApexTestResult> successTests, string linkToResults){
        Integer totalTests = failedTests.size() + successTests.size();
        String testResultBody = '<table><tbody><tr class="firstTr"><td>    Tests Run:  '+ totalTests +'';
        testResultBody += '</td></tr><tr><td>Failure Count:  '+ failedTests.size() +'';
        testResultBody += '</td></tr><tr><td>Success Count:  '+ successTests.size() +'';
        testResultBody += '</td></tr></tbody></table>';
        testResultBody += '';
        testResultBody += '<a href="'+linkToResults+'">Link to Results</a>';
        testResultBody += '';
        testResultBody += '<div style="margin: 5px 0px; font-weight: bold;">Test Failures</div>';

        testResultBody += '<table><tr>';
        testResultBody += '<th style="text-align: left; padding-left: 5px;">Test Class</th>';
        testResultBody += '<th style="text-align: left; padding-left: 5px;">Unit Test</th>';
        testResultBody += '<th style="text-align: left; padding-left: 5px;">Message</th>';
        testResultBody += '<th style="text-align: left; padding-left: 5px;">Stack Trace</th>';
        testResultBody += '<th style="text-align: left; padding-left: 5px;">Time (Ms)</th>';
        testResultBody += '</tr>';
        String testMethodResult;
        Integer bodySize = 0;
        for (ApexTestResult testFailure : failedTests){
            testMethodResult = '<tr>';
            testMethodResult += '<td style="padding: 5px; vertical-align: top;">' + testFailure.ApexClass.Name +'';
            testMethodResult += '<td style="padding: 5px; vertical-align: top;">' + testFailure.MethodName +'';
            testMethodResult += '<td style="padding: 5px; vertical-align: top;">' + testFailure.message +'';
            testMethodResult += '<td style="padding: 5px; vertical-align: top;">' + testFailure.stackTrace +'';
            testMethodResult += '<td style="padding: 5px; vertical-align: top;">' + testFailure.ApexLog.DurationMilliseconds +'';
            testMethodResult += '</tr>';
            bodySize = testResultBody.length() + testMethodResult.length() + 8;
            system.debug('&&& size:'+bodySize);
            if (bodySize < 32000) {
                testResultBody += testMethodResult;
            } else {
                break;
            }
        }
        testResultBody += '</table>';
        return testResultBody;
    }

 	/* 
 	* Get the status and pass rate for each class whose tests were run by the job that
  	*  corresponds to the specified job IDs.
  	*/ 
    public static List<ApexTestQueueItem> checkClassStatus(Set<ID> jobIds) {
        ApexTestQueueItem[] items = [SELECT ApexClass.Name, Status, ExtendedStatus, ParentJobId
            						 FROM ApexTestQueueItem 
            						 WHERE ParentJobId in :jobIds];
            
        for (ApexTestQueueItem item : items) {
            String extStatus = item.extendedstatus == null ? '' : item.extendedStatus;
            System.debug(item.ApexClass.Name + ': ' + item.Status + extStatus);
        }
        return items;
    }

    /* 
     * Get the result for each test method that was executed
  	*/ 
    public static List<ApexTestResult> checkMethodStatus(Set<ID> jobIds) {
        ApexTestResult[] results = [SELECT Outcome, MethodName, Message, StackTrace, AsyncApexJobId, ApexClass.Name,
                                       ApexClass.Body, ApexClass.LengthWithoutComments, ApexClass.NamespacePrefix,
                   					   ApexClass.Status, ApexLogId, ApexLog.DurationMilliseconds, ApexLog.Operation,
                                       ApexLog.Request, ApexLog.Status, ApexLog.Location, ApexLog.Application, SystemModstamp
            						FROM ApexTestResult 
            						WHERE AsyncApexJobId in :jobIds];
        /*for (ApexTestResult atr : results) {
            System.debug(atr.ApexClass.Name + '.' + atr.MethodName + ': ' + atr.Outcome);
            if (atr.message != null) {
                System.debug(atr.Message + '\n at ' + atr.StackTrace);
            }
        } */
        return results;
    }
}